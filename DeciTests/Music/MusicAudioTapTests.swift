// DeciTests/Music/MusicAudioTapTests.swift
// The tap proof: a short stereo fragmented AAC mp4 (the shape YouTube serves) is decoded offline through
// AVAssetReaderAudioMixOutput with the MTAudioProcessingTap mix attached. Nothing is played, nothing reaches a device.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("MusicAudioTap")
struct MusicAudioTapTests {
    private static let rate = 44_100.0

    /// Writes a stereo tone, reads it once untouched for the reference, and hands both to `body`.
    private func withTone(
        frequency: Double = 1_000,
        amplitude: Float = 0.2,
        seconds: Double = 1.5,
        rate: Double = MusicAudioTapTests.rate,
        _ body: (_ url: URL, _ reference: [Float]) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("deci-tap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let wave = MusicTestSignal.sine(frequency: frequency, amplitude: amplitude, sampleRate: rate, frames: Int(rate * seconds))
        var interleaved = [Float](repeating: 0, count: wave[0].count * 2)
        for frame in 0..<wave[0].count {
            interleaved[frame * 2] = wave[0][frame]
            interleaved[frame * 2 + 1] = wave[1][frame]
        }
        let url = directory.appendingPathComponent("tone.mp4")
        try await ToneFile.write(interleavedStereo: interleaved, sampleRate: rate, to: url)
        let reference = try await ToneFile.read(url: url, tappedBy: nil)
        try await body(url, reference)
    }

    private func channel(_ interleaved: [Float], _ index: Int) -> [Float] {
        stride(from: index, to: interleaved.count, by: 2).map { interleaved[$0] }
    }

    /// RMS of the middle of the signal, clear of the encoder's priming at the start and the tail at the end.
    private func bodyRMS(_ interleaved: [Float]) -> Float {
        let left = channel(interleaved, 0)
        return MusicTestSignal.rms(Array(left[(left.count / 4)..<(left.count * 3 / 4)]))
    }

    // MARK: - The proof

    @Test("the reference file decodes to a real stereo tone")
    func referenceIsSane() async throws {
        try await withTone { _, reference in
            #expect(reference.count > 44_100 * 2, "1.5 s of stereo")
            #expect(abs(bodyRMS(reference) - Float(0.2) / Float(2).squareRoot()) < 0.01)
        }
    }

    @Test("the process callback runs, and the format it is given is recorded")
    func processRunsAndFormatIsRecorded() async throws {
        try await withTone { url, reference in
            let chain = MusicDSPChain(sampleRate: Self.rate)
            #expect(chain.framesProcessed == 0)
            #expect(chain.observedFormat == nil)

            let tapped = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(chain.framesProcessed > 0, "the tap's process callback must run")
            #expect(chain.framesProcessed >= tapped.count / 2, "it saw every frame that was read")
            #expect(tapped.count == reference.count, "pass-through does not change the length")

            let format = try #require(chain.observedFormat, "prepare must record the processing format")
            // What the tap is handed: logged for the record, and the parts the DSP depends on are asserted.
            print("MusicAudioTap observed format: \(format)")
            #expect(format.isFloat32, "the DSP works on Float32")
            #expect(format.channelCount == 2)
            #expect(format.sampleRate == Self.rate)
        }
    }

    @Test("unity gain with a flat EQ passes the audio through")
    func unityPassesThrough() async throws {
        try await withTone { url, reference in
            let chain = MusicDSPChain(sampleRate: Self.rate)
            let tapped = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(abs(bodyRMS(tapped) / bodyRMS(reference) - 1) < 0.01)
        }
    }

    @Test("gain 0.5 halves the peak and the level")
    func halfGain() async throws {
        try await withTone { url, reference in
            let chain = MusicDSPChain(sampleRate: Self.rate)
            chain.setTargetGain(0.5, snap: true)
            let tapped = try await ToneFile.read(url: url, tappedBy: chain)

            let referencePeak = MusicTestSignal.peak(reference)
            let tappedPeak = MusicTestSignal.peak(tapped)
            #expect(referencePeak > 0.15)
            #expect(abs(tappedPeak / referencePeak - 0.5) < 0.02, "peak ratio \(tappedPeak / referencePeak)")
            #expect(abs(bodyRMS(tapped) / bodyRMS(reference) - 0.5) < 0.01)
        }
    }

    @Test("mute gives silence from the first sample to the last")
    func muteIsSilent() async throws {
        try await withTone { url, reference in
            let chain = MusicDSPChain(sampleRate: Self.rate)
            chain.setTargetGain(0, snap: true)
            let tapped = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(tapped.count == reference.count)
            #expect(MusicTestSignal.peak(tapped) == 0)
            #expect(MusicTestSignal.peak(reference) > 0.15, "there was something to silence")
        }
    }

    @Test("an EQ band boost raises the energy at that band and leaves a distant band alone")
    func eqBandBoost() async throws {
        try await withTone(frequency: 1_000, amplitude: 0.1) { url, reference in
            var gains = [Float](repeating: 0, count: EQSettings.bandCount)
            gains[5] = 12   // 1 kHz

            let near = MusicDSPChain(sampleRate: Self.rate)
            near.setEQ(EQSettings(bandGains: gains))
            let boosted = try await ToneFile.read(url: url, tappedBy: near)
            #expect(abs(bodyRMS(boosted) / bodyRMS(reference) - 3.98) < 0.3, "ratio \(bodyRMS(boosted) / bodyRMS(reference))")

            gains[5] = 0
            gains[0] = 12   // 31 Hz
            let far = MusicDSPChain(sampleRate: Self.rate)
            far.setEQ(EQSettings(bandGains: gains))
            let untouched = try await ToneFile.read(url: url, tappedBy: far)
            #expect(abs(bodyRMS(untouched) / bodyRMS(reference) - 1) < 0.05)
        }
    }

    @Test("nothing reaches the reader unprocessed: the first sample already passes through the tap")
    func mixIsAttachedBeforeTheFirstSample() async throws {
        try await withTone { url, reference in
            #expect(abs(reference.prefix(4_000).max() ?? 0) > 0.01, "the reference has signal right at the start")

            let chain = MusicDSPChain(sampleRate: Self.rate)
            chain.setTargetGain(0, snap: true)
            let tapped = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(tapped.prefix(4_096).allSatisfy { $0 == 0 }, "a sample that skipped the tap would be audible here")
        }
    }

    // MARK: - Sample rate

    @Test("a file at another rate than the chain is passed through, then processed once the chain is rebuilt")
    func sampleRateMismatch() async throws {
        try await withTone(frequency: 1_000, amplitude: 0.1) { url, reference in
            var gains = [Float](repeating: 0, count: EQSettings.bandCount)
            gains[5] = 12
            let chain = MusicDSPChain(sampleRate: 48_000)
            chain.setEQ(EQSettings(bandGains: gains))

            // The read blocks the main queue, so the chain cannot rebuild yet: the EQ must be bypassed, not wrong.
            let first = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(abs(bodyRMS(first) / bodyRMS(reference) - 1) < 0.02)

            let rebuilt = await waitUntil(timeout: .seconds(10)) { chain.processorSampleRate == Self.rate }
            #expect(rebuilt, "the chain hops to the main queue and rebuilds for the stream's rate")

            let second = try await ToneFile.read(url: url, tappedBy: chain)
            #expect(abs(bodyRMS(second) / bodyRMS(reference) - 3.98) < 0.3)
        }
    }

    // MARK: - Mix construction

    @Test("the mix targets exactly the first audio track")
    func mixTargetsTheFirstAudioTrack() async throws {
        try await withTone { url, _ in
            let asset = AVURLAsset(url: url)
            let chain = MusicDSPChain(sampleRate: Self.rate)
            let mix = try #require(await MusicAudioTap.makeAudioMix(for: asset, chain: chain))
            let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)

            let parameters = mix.inputParameters
            #expect(parameters.count == 1)
            #expect(parameters.first?.trackID == track.trackID)
            #expect(parameters.first?.audioTapProcessor != nil)
        }
    }

    @Test("an asset with no readable audio track gives no mix, so the caller plays it unprocessed")
    func noMixWithoutATrack() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("deci-tap-missing-\(UUID().uuidString).mp4")
        let mix = await MusicAudioTap.makeAudioMix(for: AVURLAsset(url: missing), chain: MusicDSPChain(sampleRate: 48_000))
        #expect(mix == nil)
    }

    // MARK: - Lifetime

    @Test("the tap lets go of the chain when it is finalized, and holds nothing else")
    func finalizeReleasesTheContext() async throws {
        try await withTone { url, _ in
            weak var weakChain: MusicDSPChain?
            do {
                let chain = MusicDSPChain(sampleRate: Self.rate)
                weakChain = chain
                _ = try await ToneFile.read(url: url, tappedBy: chain)
            }
            let released = await waitUntil(timeout: .seconds(10)) { weakChain == nil }
            #expect(released, "the tap context is Unmanaged.passRetained and must be released in finalize")
        }
    }
}
