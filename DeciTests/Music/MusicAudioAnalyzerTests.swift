// DeciTests/Music/MusicAudioAnalyzerTests.swift
// The pure analysis core on plain Float arrays: K-weighting, BS.1770 loudness and gates, silence edges,
// the energy curve, intro and outro, and block-size independence. No file, no AVFoundation.

import Foundation
import Testing
@testable import Deci

/// Signal builders and a feeder shared by the analyzer suites.
nonisolated enum AnalyzerSignal {
    static let rate = 44_100.0

    /// Peak amplitude of a sine whose RMS is `db` dBFS.
    static func amplitude(rmsDb db: Double) -> Float { Float(pow(10, db / 20) * 2.0.squareRoot()) }

    /// A sine at `rmsDb` (RMS dBFS), nil for digital silence.
    static func segment(rmsDb: Double?, seconds: Double, rate: Double = AnalyzerSignal.rate, channels: Int = 2) -> [[Float]] {
        let frames = Int((seconds * rate).rounded())
        guard let rmsDb else { return MusicTestSignal.constant(0, frames: frames, channels: channels) }
        return MusicTestSignal.sine(frequency: 1000, amplitude: amplitude(rmsDb: rmsDb), sampleRate: rate, frames: frames, channels: channels)
    }

    static func concat(_ parts: [[[Float]]]) -> [[Float]] {
        guard let first = parts.first else { return [] }
        return (0..<first.count).map { channel in parts.flatMap { $0[channel] } }
    }

    /// A sine whose peak level follows `peakDb(t)` per sample.
    static func envelope(seconds: Double, rate: Double = AnalyzerSignal.rate, peakDb: (Double) -> Double) -> [Float] {
        let frames = Int((seconds * rate).rounded())
        return (0..<frames).map { frame in
            let time = Double(frame) / rate
            return Float(pow(10, peakDb(time) / 20) * sin(2 * Double.pi * 1000 * time))
        }
    }

    /// Feeds planar channels in blocks of `block` frames and finishes.
    static func measure(
        _ channels: [[Float]], rate: Double = AnalyzerSignal.rate, block: Int = 4096, exactDuration: Double? = nil
    ) -> MusicAnalysisMeasurement {
        var analyzer = MusicAudioAnalyzer(sampleRate: rate, channels: channels.count)
        let buffers = channels.map { channel -> UnsafeMutableBufferPointer<Float> in
            let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: max(1, channel.count))
            _ = buffer.initialize(from: channel)
            return buffer
        }
        defer { for buffer in buffers { buffer.deallocate() } }
        let total = channels.first?.count ?? 0
        var start = 0
        while start < total {
            let end = min(total, start + block)
            analyzer.consume(planar: buffers.map { UnsafeBufferPointer(rebasing: $0[start..<end]) })
            start = end
        }
        return analyzer.finish(exactDuration: exactDuration)
    }
}

@MainActor
@Suite("MusicAudioAnalyzer")
struct MusicAudioAnalyzerTests {

    // MARK: K-weighting

    @Test("48 kHz coefficients equal the BS.1770-4 table to 1e-9")
    func kWeightTable48k() {
        let (shelf, highpass) = MusicAudioAnalyzer.kWeightingCoefficients(sampleRate: 48_000)
        #expect(abs(shelf.b0 - 1.53512485958697) < 1e-9)
        #expect(abs(shelf.b1 - -2.69169618940638) < 1e-9)
        #expect(abs(shelf.b2 - 1.19839281085285) < 1e-9)
        #expect(abs(shelf.a1 - -1.69065929318241) < 1e-9)
        #expect(abs(shelf.a2 - 0.73248077421585) < 1e-9)
        #expect(abs(highpass.b0 - 1) < 1e-9)
        #expect(abs(highpass.b1 - -2) < 1e-9)
        #expect(abs(highpass.b2 - 1) < 1e-9)
        #expect(abs(highpass.a1 - -1.99004745483398) < 1e-9)
        #expect(abs(highpass.a2 - 0.99007225036621) < 1e-9)
    }

    private func kGainDb(_ frequency: Double, sampleRate: Double) -> Double {
        let (shelf, highpass) = MusicAudioAnalyzer.kWeightingCoefficients(sampleRate: sampleRate)
        return shelf.gainDb(frequency: frequency, sampleRate: sampleRate)
            + highpass.gainDb(frequency: frequency, sampleRate: sampleRate)
    }

    @Test("K-weighting gain at 1 kHz is the standard +0.69 dB, which the -0.691 offset cancels")
    func gainAtOneKilohertz() {
        #expect(abs(kGainDb(1000, sampleRate: 48_000) - 0.691) < 0.05)
    }

    @Test("The 44.1 kHz derived response matches the 48 kHz response at the same frequencies")
    func derivedResponse() {
        for frequency in [50.0, 100, 500, 1000, 3000, 6000, 10_000, 15_000] {
            let at441 = kGainDb(frequency, sampleRate: 44_100)
            let at48 = kGainDb(frequency, sampleRate: 48_000)
            #expect(abs(at441 - at48) < 0.05, "f=\(frequency) 44.1k=\(at441) 48k=\(at48)")
        }
    }

    // MARK: Loudness

    @Test("Stereo 1 kHz at -23 dBFS peak in both channels reads -23 LUFS (EBU Tech 3341)")
    func stereoOracle() throws {
        let m = AnalyzerSignal.measure(MusicTestSignal.sine(frequency: 1000, amplitude: Float(pow(10, -23.0 / 20)), sampleRate: 44_100, frames: 44_100 * 10))
        #expect(abs(try #require(m.integratedLUFS) - -23) < 0.1)
    }

    @Test("A 0 dBFS 1 kHz sine in one channel reads -3.01 LUFS, and in both channels 0 LUFS")
    func fullScale() throws {
        let one = AnalyzerSignal.measure(MusicTestSignal.sine(frequency: 1000, amplitude: 1, sampleRate: 44_100, frames: 44_100 * 6, channels: 1))
        #expect(abs(try #require(one.integratedLUFS) - -3.01) < 0.1)
        let two = AnalyzerSignal.measure(MusicTestSignal.sine(frequency: 1000, amplitude: 1, sampleRate: 44_100, frames: 44_100 * 6, channels: 2))
        #expect(abs(try #require(two.integratedLUFS) - 0) < 0.1)
    }

    @Test("A mono file reads 3 dB below the same signal duplicated into stereo")
    func monoVersusStereo() throws {
        let mono = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -20, seconds: 8, channels: 1))
        let stereo = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -20, seconds: 8, channels: 2))
        let difference = try #require(stereo.integratedLUFS) - (try #require(mono.integratedLUFS))
        #expect(abs(difference - 3.0103) < 0.05)
    }

    @Test("The loudness of a 48 kHz and a 44.1 kHz render of the same tone agree")
    func sampleRateAgreement() throws {
        let a = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -18, seconds: 6, rate: 44_100), rate: 44_100)
        let b = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -18, seconds: 6, rate: 48_000), rate: 48_000)
        #expect(abs(try #require(a.integratedLUFS) - (try #require(b.integratedLUFS))) < 0.05)
    }

    @Test("A patch 36 dB under the track is dropped by the relative gate")
    func relativeGate() throws {
        let loud = AnalyzerSignal.segment(rmsDb: -14, seconds: 12)
        let reference = AnalyzerSignal.measure(loud)
        let patched = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: -14, seconds: 12),
            AnalyzerSignal.segment(rmsDb: -50, seconds: 5),
            AnalyzerSignal.segment(rmsDb: -14, seconds: 12),
        ]))
        let expected = try #require(reference.integratedLUFS)
        #expect(abs(try #require(patched.integratedLUFS) - expected) < 0.1)
        // Ungated, the patch would pull the mean down by about 0.7 dB.
        let ungated = expected + 10 * log10(24.0 / 29.0)
        #expect(ungated < expected - 0.5)
    }

    @Test("Loud audio followed by a long -75 dBFS tail reads like the loud part alone")
    func absoluteGateFollowedByQuiet() throws {
        let loud = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -14, seconds: 10))
        let both = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: -14, seconds: 10),
            AnalyzerSignal.segment(rmsDb: -75, seconds: 20),
        ]))
        #expect(abs(try #require(both.integratedLUFS) - (try #require(loud.integratedLUFS))) < 0.1)
    }

    @Test("Everything under -70 LUFS is gated out and the loudness is nil")
    func allGatedOut() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -80, seconds: 5))
        #expect(m.integratedLUFS == nil)
    }

    @Test("integratedLUFS(blockMeanSquares:) applies the -70 absolute and -10 LU relative gates")
    func staticGates() throws {
        func z(_ lufs: Double) -> Double { pow(10, (lufs + 0.691) / 10) }
        #expect(MusicAudioAnalyzer.integratedLUFS(blockMeanSquares: []) == nil)
        #expect(MusicAudioAnalyzer.integratedLUFS(blockMeanSquares: [z(-71), z(-90)]) == nil)
        let steady = try #require(MusicAudioAnalyzer.integratedLUFS(blockMeanSquares: Array(repeating: z(-23), count: 40)))
        #expect(abs(steady - -23) < 1e-9)
        // Blocks 22 LU under the loud ones fall below the relative gate (about -36 for this mix).
        let mixed = try #require(MusicAudioAnalyzer.integratedLUFS(blockMeanSquares: Array(repeating: z(-23), count: 40) + Array(repeating: z(-45), count: 40)))
        #expect(abs(mixed - -23) < 1e-9)
        // Blocks 6 LU under stay in.
        let near = try #require(MusicAudioAnalyzer.integratedLUFS(blockMeanSquares: Array(repeating: z(-23), count: 40) + Array(repeating: z(-29), count: 40)))
        #expect(near < -23 && near > -26)
        #expect(abs(MusicAudioAnalyzer.blockLUFS(meanSquare: 1) - -0.691) < 1e-12)
    }

    @Test("Sample peak is the largest absolute sample in dBFS")
    func samplePeak() {
        var channels = AnalyzerSignal.segment(rmsDb: -30, seconds: 2)
        channels[1][5000] = -0.5
        let m = AnalyzerSignal.measure(channels)
        #expect(abs(m.samplePeakDb - 20 * log10(0.5)) < 1e-6)
    }

    // MARK: Silence edges

    @Test("2.00 s silence, 5 s tone, 1.50 s silence: edges at 2.00 and 7.00")
    func silenceEdges() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: nil, seconds: 2),
            AnalyzerSignal.segment(rmsDb: -20, seconds: 5),
            AnalyzerSignal.segment(rmsDb: nil, seconds: 1.5),
        ]))
        #expect(abs(m.silenceStart - 2.0) <= 0.01)
        #expect(abs(m.silenceEnd - 7.0) <= 0.01)
        #expect(abs(m.duration - 8.5) < 1e-6)
        #expect(!m.isSilent)
    }

    @Test("A tone at -61 dBFS counts as silence and -59 as audio")
    func threshold() {
        let quiet = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: -61, seconds: 3), AnalyzerSignal.segment(rmsDb: -20, seconds: 2),
        ]))
        #expect(abs(quiet.silenceStart - 3.0) <= 0.01)
        let audible = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: -59, seconds: 3), AnalyzerSignal.segment(rmsDb: -20, seconds: 2),
        ]))
        #expect(audible.silenceStart == 0)
    }

    @Test("The louder channel decides: a tone in the right channel only is audio")
    func loudestChannel() {
        var channels = AnalyzerSignal.segment(rmsDb: nil, seconds: 1)
        channels[1] = AnalyzerSignal.segment(rmsDb: -20, seconds: 1, channels: 1)[0]
        #expect(!AnalyzerSignal.measure(channels).isSilent)
    }

    @Test("A file that starts loud has silenceStart 0, and one that ends loud has silenceEnd == duration")
    func loudEdges() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -12, seconds: 4))
        #expect(m.silenceStart == 0)
        #expect(abs(m.silenceEnd - 4) < 1e-9)
    }

    @Test("An all-silent buffer, a -70 dBFS buffer and an empty input are flagged silent")
    func allSilent() {
        for channels in [
            AnalyzerSignal.segment(rmsDb: nil, seconds: 3),
            AnalyzerSignal.segment(rmsDb: -70, seconds: 3),
            [[Float]](repeating: [], count: 2),
        ] {
            let m = AnalyzerSignal.measure(channels)
            #expect(m.isSilent)
            #expect(m.silenceStart == 0)
            #expect(m.silenceEnd == m.duration)
        }
    }

    @Test("silenceEdges(windowRMSdB:) finds first and last window above the threshold and is nil when none is")
    func staticSilenceEdges() throws {
        let windows: [Float] = [-90, -80, -30, -20, -45, -70]
        let edges = try #require(MusicAudioAnalyzer.silenceEdges(windowRMSdB: windows, window: 0.01, duration: 0.06))
        #expect(abs(edges.start - 0.02) < 1e-12)
        #expect(abs(edges.end - 0.05) < 1e-12)
        #expect(MusicAudioAnalyzer.silenceEdges(windowRMSdB: [-61, -90], window: 0.01, duration: 0.02) == nil)
    }

    // MARK: Energy

    @Test("The energy curve codes a known level as (dB + 90) * 2 within one code, one code per 100 ms")
    func energyCodes() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -20, seconds: 5))
        #expect(m.energy.count == 50)
        let expected = Int(MusicAnalysis.energyCode(forDb: -20))
        #expect(expected == 140)
        for code in m.energy { #expect(abs(Int(code) - expected) <= 1) }
    }

    @Test("The energy count is ceil(duration / 0.1) including a partial last block, and silence codes 0")
    func energyCount() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: nil, seconds: 0.5), AnalyzerSignal.segment(rmsDb: -20, seconds: 1.234),
        ]))
        #expect(m.energy.count == 18)
        #expect(m.energy.prefix(5).allSatisfy { $0 == 0 })
        #expect(abs(Int(m.energy[17]) - 140) <= 1)
    }

    @Test("A ten minute file's curve is under 10 KB")
    func energySize() {
        // 600 s of a mono 8 kHz tone: cheap to build, still 6000 blocks.
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -25, seconds: 600, rate: 8000, channels: 1), rate: 8000)
        #expect(m.energy.count == 6000)
        #expect(MusicAnalysisPayload.encode(m.energy).count < 10_000)
    }

    @Test("quantizeEnergy uses the shared code mapping")
    func quantize() {
        #expect(MusicAudioAnalyzer.quantizeEnergy([-90, -89.75, -0.1, 0, 5, -.infinity, -120]) == [0, 1, 180, 180, 180, 0, 0])
    }

    // MARK: Intro and outro

    @Test("Ramp, steady body, fade: intro end and outro start land where the rule puts them")
    func syntheticSong() {
        // Peak dB: ramp -40 to -10 over 6 s, steady 20 s, fade to -50 over 8 s. Body is -10 peak,
        // so body - 6 dB is crossed at -16 peak: 4.8 s up the ramp and 27.2 s down the fade.
        let wave = AnalyzerSignal.envelope(seconds: 34) { time in
            if time < 6 { return -40 + 30 * time / 6 }
            if time < 26 { return -10 }
            return -10 - 40 * (time - 26) / 8
        }
        let m = AnalyzerSignal.measure([wave, wave])
        #expect(abs(m.introEnd - 4.8) <= 1.0, "introEnd \(m.introEnd)")
        #expect(abs(m.outroStart - 27.2) <= 1.0, "outroStart \(m.outroStart)")
        #expect(m.silenceStart <= m.introEnd && m.introEnd <= m.outroStart && m.outroStart <= m.silenceEnd)
    }

    @Test("A steady tone has no intro and no outro")
    func steadyTone() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: nil, seconds: 1),
            AnalyzerSignal.segment(rmsDb: -18, seconds: 10),
            AnalyzerSignal.segment(rmsDb: nil, seconds: 1),
        ]))
        #expect(m.introEnd == m.silenceStart)
        #expect(m.outroStart == m.silenceEnd)
    }

    @Test("silenceStart <= introEnd <= outroStart <= silenceEnd <= duration for 200 random envelopes")
    func randomInvariants() {
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        for _ in 0..<200 {
            let blocks = 20 + Int(next() * 3000)
            var level = -60 + next() * 50
            let energy: [Float] = (0..<blocks).map { _ in
                level = max(-90, min(0, level + (next() - 0.5) * 12))
                return Float(level)
            }
            let duration = Double(blocks) * 0.1
            let a = next() * duration, b = next() * duration
            let (start, end) = (min(a, b), max(a, b))
            let (intro, outro) = MusicAudioAnalyzer.introOutro(
                energyDb: energy, silenceStart: start, silenceEnd: end, duration: duration, block: 0.1
            )
            #expect(start <= intro && intro <= outro && outro <= end && end <= duration)
        }
    }

    // MARK: Streaming

    @Test("Blocks of 1, 513, 4096 and 100000 frames give the same measurement")
    func blockSizeEquivalence() throws {
        let channels = AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: nil, seconds: 0.7),
            AnalyzerSignal.segment(rmsDb: -30, seconds: 1.5),
            AnalyzerSignal.segment(rmsDb: -12, seconds: 2.5),
            AnalyzerSignal.segment(rmsDb: nil, seconds: 0.3),
        ])
        let reference = AnalyzerSignal.measure(channels, block: 4096)
        for block in [1, 513, 100_000] {
            let m = AnalyzerSignal.measure(channels, block: block)
            #expect(m.energy == reference.energy, "block \(block)")
            #expect(m.silenceStart == reference.silenceStart && m.silenceEnd == reference.silenceEnd)
            #expect(m.introEnd == reference.introEnd && m.outroStart == reference.outroStart)
            #expect(abs(try #require(m.integratedLUFS) - (try #require(reference.integratedLUFS))) < 1e-9)
            #expect(m.samplePeakDb == reference.samplePeakDb)
        }
    }

    @Test("Interleaved input gives the same measurement as planar input")
    func interleavedEqualsPlanar() throws {
        let channels = AnalyzerSignal.concat([
            AnalyzerSignal.segment(rmsDb: -25, seconds: 2), AnalyzerSignal.segment(rmsDb: -10, seconds: 2),
        ])
        var interleaved = [Float](repeating: 0, count: channels[0].count * 2)
        for frame in 0..<channels[0].count {
            interleaved[frame * 2] = channels[0][frame]
            interleaved[frame * 2 + 1] = channels[1][frame]
        }
        var analyzer = MusicAudioAnalyzer(sampleRate: 44_100, channels: 2)
        interleaved.withUnsafeBufferPointer { analyzer.consume(interleaved: $0, frames: channels[0].count) }
        let a = analyzer.finish(exactDuration: nil)
        let b = AnalyzerSignal.measure(channels)
        #expect(a.energy == b.energy)
        #expect(abs(try #require(a.integratedLUFS) - (try #require(b.integratedLUFS))) < 1e-9)
    }

    @Test("An exact duration shorter than the audio clamps the edges, the curve and the duration")
    func exactDurationClamp() {
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -20, seconds: 6), exactDuration: 4)
        #expect(m.duration == 4)
        #expect(m.silenceEnd <= 4)
        #expect(m.energy.count == 40)
    }

    // MARK: Mapping

    @Test("The measurement maps onto a MusicAnalysis entry")
    func mapping() throws {
        let m = AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -20, seconds: 5))
        let format = MusicAnalysis.Format(codec: "mp4a.40.2", itag: 0, durationMs: 5000)
        let entry = MusicAnalysis(
            videoId: "abcDEF12345", measurement: m, format: format, source: .backgroundCache,
            analyzedAt: Date(timeIntervalSince1970: 100), youtubeLoudnessDb: -6.3, youtubePerceptualLoudnessDb: nil
        )
        #expect(entry.version == MusicAnalysis.currentVersion)
        #expect(entry.energy == m.energy)
        #expect(entry.integratedLUFS == m.integratedLUFS)
        #expect(entry.silenceEnd == m.silenceEnd && entry.introEnd == m.introEnd)
        #expect(entry.youtubeLoudnessDb == -6.3 && entry.youtubePerceptualLoudnessDb == nil)
        let silent = MusicAnalysis(
            videoId: "abcDEF12345", measurement: AnalyzerSignal.measure(AnalyzerSignal.segment(rmsDb: -85, seconds: 2)),
            format: format, source: .download
        )
        #expect(silent.integratedLUFS == -.infinity)
        #expect(silent.samplePeakDb.isFinite)
    }
}
