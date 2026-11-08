// DeciTests/Music/LiveChecks/LiveAudio.swift
// The real engine, silently. The two AVPlayer decks run for real, but the DSP chain's render path has a DEBUG seam
// (MusicRenderRecorder) that records every lease's output after the whole chain (fade included) with the item time of its
// first frame, and then zeroes it, so the device gets digital silence and the owner hears nothing. Nothing touches the
// system output device or any audio setting. Before the engine checks run, a real song is played through the chain and
// the recorder must see it, or the checks do not run.

import Foundation
import AVFoundation
import CoreMedia
@testable import Deci

@MainActor
final class LiveAudio {
    /// What the probe measured, for the report.
    let probePeak: Float
    let deviceName = "default output untouched, chain output zeroed after recording"

    private static var cached: LiveAudio?
    private(set) static var failure: String?

    /// nil when the recorder cannot be proven; `failure` says why.
    static func shared(world: LiveWorld) async -> LiveAudio? {
        if let cached { return cached }
        if failure != nil { return nil }
        MusicRenderRecorder.mutesOutput = true
        let recorder = MusicRenderRecorder(seconds: 30)
        MusicRenderRecorder.current = recorder
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(1, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        engine.load(world.songs[0].stream, startAt: 40, autoplay: true)
        let playing = await waitUntil(timeout: .seconds(30)) {
            engine.position > 41 && engine.avPlayer.timeControlStatus == .playing
        }
        guard playing else {
            engine.unload()
            MusicRenderRecorder.current = nil
            failure = "the probe song never played"
            return nil
        }
        try? await Task.sleep(for: .seconds(2))
        let heard = recorder.snapshot()
        engine.unload()
        MusicRenderRecorder.current = nil
        let peak = MusicTestSignal.peak(heard.samples)
        guard peak > 0.01, heard.records.contains(where: { $0.sourceStart.isFinite }) else {
            failure = "the recorder does not see the players (probe peak \(peak))"
            return nil
        }
        let audio = LiveAudio(probePeak: peak)
        cached = audio
        return audio
    }

    /// Back to the normal render path (the zeroing is for these checks only).
    static func end() {
        MusicRenderRecorder.current = nil
        MusicRenderRecorder.mutesOutput = false
    }

    private init(probePeak: Float) { self.probePeak = probePeak }

    /// A fresh two-deck engine with its own chain at unity gain on the default output (which carries only zeros).
    func makeEngine() -> (engine: AVPlaybackEngine, chain: MusicDSPChain) {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(1, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.avPlayer.preventsDisplaySleepDuringVideoPlayback = false
        return (engine, chain)
    }
}
