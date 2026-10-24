// Deci/Audio/Extensions/AudioDeviceID+Latency.swift
import AudioToolbox
import Foundation

// MARK: - Output Latency

nonisolated extension AudioDeviceID {
    /// The device's total output latency: its device latency, safety offset and first output stream's latency, all
    /// output scope, with its nominal rate. nil when any of them cannot be read or the device has no output stream.
    func readOutputLatency() -> OutputLatency? {
        guard let device: UInt32 = try? read(kAudioDevicePropertyLatency, scope: .output, defaultValue: 0),
              let safetyOffset: UInt32 = try? read(kAudioDevicePropertySafetyOffset, scope: .output, defaultValue: 0),
              let stream = firstOutputStreamID(),
              let streamLatency = stream.readStreamLatency(),
              let rate = try? readNominalSampleRate() else { return nil }
        return OutputLatency.total(device: device, safetyOffset: safetyOffset, stream: streamLatency, sampleRate: rate)
    }
}

nonisolated extension AudioObjectID {
    /// A stream's own latency in frames. Output scope first; a stream that does not answer there is asked globally.
    func readStreamLatency() -> UInt32? {
        for scope in [AudioScope.output, .global] {
            if let frames: UInt32 = try? read(kAudioStreamPropertyLatency, scope: scope, defaultValue: 0) {
                return frames
            }
        }
        return nil
    }
}
