// DeciTests/Music/LiveChecks/LiveAudio.swift
// The real engine, silently. A muted Core Audio process tap on this process (OwnProcessCapture, the one the beat sync
// spike uses) takes what the two AVPlayer decks hand to the output device and plays nothing, so the owner hears nothing.
// Before any song plays at full level a real song is played through the chain at -60 dB and the capture must see it, or
// the engine checks do not run (they fall back to FakePlaybackEngine and the report says so).

import Foundation
import AVFoundation
import CoreMedia
@testable import Deci

@MainActor
final class LiveAudio {
    let capture: OwnProcessCapture
    /// What the probe measured, for the report.
    let probePeak: Float
    let deviceName: String

    private static var cached: LiveAudio?
    private(set) static var failure: String?

    /// nil when the silent capture cannot be proven; `failure` says why.
    static func shared(world: LiveWorld) async -> LiveAudio? {
        if let cached { return cached }
        if failure != nil { return nil }
        do {
            var started: OwnProcessCapture?
            var lastError: any Error = LiveSongs.Failure(description: "no attempt")
            for attempt in 0..<3 {
                do {
                    let attemptCapture = try OwnProcessCapture(deviceUID: nil, maxSeconds: 150)
                    try attemptCapture.start()
                    started = attemptCapture
                    break
                } catch {
                    lastError = error
                    print("LIVE capture attempt \(attempt + 1) failed: \(error)")
                    try? await Task.sleep(for: .seconds(2))
                }
            }
            guard let capture = started else { throw lastError }
            let chain = MusicDSPChain(sampleRate: capture.sampleRate)
            chain.setTargetGain(0.001, snap: true)
            let engine = AVPlaybackEngine(chain: chain)
            engine.setOutputDevice(uid: capture.outputDeviceUID)
            engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
            capture.beginRecording()
            engine.load(world.songs[0].stream, startAt: 40, autoplay: true)
            let playing = await waitUntil(timeout: .seconds(30)) {
                engine.position > 41 && engine.avPlayer.timeControlStatus == .playing
            }
            guard playing else {
                _ = capture.endRecording()
                engine.unload()
                capture.stop()
                failure = "the probe song never played"
                return nil
            }
            try? await Task.sleep(for: .seconds(2))
            let heard = capture.endRecording()
            engine.unload()
            let peak = MusicTestSignal.peak(heard.samples)
            guard peak > 1e-5, peak < 0.05 else {
                capture.stop()
                failure = "the capture does not see the players (probe peak \(peak))"
                return nil
            }
            let audio = LiveAudio(capture: capture, probePeak: peak)
            cached = audio
            return audio
        } catch {
            failure = "no silent capture: \(error)"
            return nil
        }
    }

    private init(capture: OwnProcessCapture, probePeak: Float) {
        self.capture = capture
        self.probePeak = probePeak
        deviceName = capture.outputDeviceName
    }

    /// A fresh two-deck engine with its own chain at unity gain, output on the captured device.
    func makeEngine() -> (engine: AVPlaybackEngine, chain: MusicDSPChain) {
        let chain = MusicDSPChain(sampleRate: capture.sampleRate)
        chain.setTargetGain(1, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.setOutputDevice(uid: capture.outputDeviceUID)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        return (engine, chain)
    }
}
