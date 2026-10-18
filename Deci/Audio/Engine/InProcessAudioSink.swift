// Deci/Audio/Engine/InProcessAudioSink.swift
import Foundation

/// A listener for audio that plays inside Deci's own process (the YouTube Music player).
///
/// The Core Audio process taps never see Deci's own output, so the engine cannot process that audio itself. It tells
/// whoever does, through this narrow seam, about the global switches and device events that normally reach its taps.
/// The engine holds the sink weakly and knows nothing about what sits behind it.
@MainActor
protocol InProcessAudioSink: AnyObject {
    /// The global loudness compensation switch changed.
    func loudnessCompensationChanged(enabled: Bool)
    /// The global loudness equalization switch changed.
    func loudnessEqualizationChanged(enabled: Bool)
    /// The AutoEQ preamp switch changed.
    func autoEQPreampChanged(enabled: Bool)
    /// The AutoEQ profile or its on/off state changed for this output device.
    func autoEQSelectionChanged(deviceUID: String)
    /// A hardware or software output volume changed on a known output device.
    func deviceVolumeChanged(deviceUID: String, volume: Float)
    /// The system default output device changed.
    func defaultDeviceChanged(uid: String)
    /// An output device connected or disconnected.
    func outputDevicesChanged()
    /// Every persisted setting was reset to its default (the settings were cleared before this call).
    func settingsDidReset()
}
