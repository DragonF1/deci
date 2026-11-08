// Deci/Music/Analysis/MusicBeatDownbeat.swift
// Tier 3b accuracy P2: which beat of the bar is beat 1, on a grid the planner already trusts. A wrong downbeat is worse
// than none (it puts the mix on beat 3 of a bar), so the answer is only given when it holds up three ways.
//
// Per beat of the grid four features are measured, each scaled by its song mean so they weigh the same:
//   kick     bass level plus bass attack (the existing bass band),
//   snare    mid-band (150 Hz to 4 kHz) spectral rise within 30 ms before to 60 ms after the beat,
//   harmony  how much the pitch-class profile changes across the beat (a chord change usually starts a bar),
//   section  how much the loudness of the next 8 beats differs from the previous 8 (sections start on bar 1).
// For every block of four beats and every hypothesis p (beat 1 is the slot k mod 4 == p) a score is the sum of
//   kick[p] over its block mean, the back-beat contrast (snare on p+1 and p+3 over p and p+2), harmony[p], section[p].
// Kick and snare alone cannot tell beat 1 from beat 3 (the same pattern fits both), so that tie is left to the harmony and
// section cues; with neither, the two scores stay level and the answer is refused.
//
// Honesty: the best phase must lead the second best by `minDownbeatMargin` standard errors over the blocks and by
// `minDownbeatEffect` in feature units (a perfectly repeating synthetic loop has no spread, so a z-score alone is not
// enough), and the halves, the thirds, the even blocks and the odd blocks must each pick the same phase.

import Foundation
import Accelerate

nonisolated extension MusicBeatFinder {
    /// Blocks of four beats needed before any answer is given.
    static let minDownbeatBlocks = 12
    /// Best minus second best phase, in standard errors over the blocks.
    static let minDownbeatMargin = 2.0
    /// Best minus second best phase, mean per block, in song-mean feature units.
    static let minDownbeatEffect = 0.3
    /// Chroma analysis: pitch classes are read from this range, and the profile windows sit this far after and before a beat.
    static let chromaLowHz = 130.0
    static let chromaHighHz = 1_800.0
    static let chromaWindow = 4_096
    static let chromaGapAfterSec = 0.10
    static let chromaGapBeforeSec = 0.02
    static let snareLowHz = 150.0
    static let snareHighHz = 4_000.0
    static let snareWindow = 1_024
    static let snareHop = 256
    /// Beats on each side of a beat that the section cue compares.
    static let sectionBeats = 8
    /// A feature is scaled by its song mean, but never by less than this: a song with no chord change or no loudness change
    /// must not have its noise stretched to the size of a real accent.
    static let harmonyFloor = 0.1
    static let sectionFloor = 0.03

    /// What the downbeat step learned. `phase` is the beat index (mod 4 from the grid anchor) taken for beat 1.
    struct DownbeatEstimate {
        var phase: Int
        /// Best minus second best, in standard errors over the blocks.
        var margin: Double
        /// Best minus second best, mean per block, in feature units.
        var effect: Double
        /// The halves, the thirds, the even blocks and the odd blocks each pick the same phase.
        var agrees: Bool
        var blocks: Int
        /// The phase each split picked: first half, second half, even blocks, odd blocks, then the three thirds.
        var splitPhases: [Int] = []
        var accepted: Bool {
            agrees && margin >= MusicBeatFinder.minDownbeatMargin && effect >= MusicBeatFinder.minDownbeatEffect
        }
        /// 0...1 as stored on the grid; 0 when the phase is not believed.
        var confidence: Double { accepted ? min(1, margin / (4 * MusicBeatFinder.minDownbeatMargin)) : 0 }
    }

    /// nil when there are too few blocks, the audio has no signal, or the task is cancelled. Otherwise the best phase with
    /// its evidence; `accepted` says whether to believe it.
    static func estimateDownbeat(
        decimated: [Float], rate: Double, grid: MusicBeatGrid, beats: ClosedRange<Int>, band: Band? = nil
    ) -> DownbeatEstimate? {
        guard rate > 0, rate.isFinite, grid.periodSec > 0, !decimated.isEmpty else { return nil }
        let band = band ?? bassBand(decimated, rate: rate)
        guard !Task.isCancelled, band.env.count == decimated.count else { return nil }
        let features = beatFeatures(decimated: decimated, rate: rate, grid: grid, beats: beats, band: band)
        guard !Task.isCancelled else { return nil }

        // Blocks of four beats that start where k mod 4 == 0 and have every feature.
        var scores: [[Double]] = []
        var k = beats.lowerBound + ((4 - ((beats.lowerBound % 4) + 4) % 4) % 4)
        while k + 3 <= beats.upperBound {
            defer { k += 4 }
            let slots = (0..<4).map { features[k - beats.lowerBound + $0] }
            guard slots.allSatisfy({ $0 != nil }) else { continue }
            let f = slots.map { $0! }
            let kickMean = f.reduce(0) { $0 + $1.kick } / 4
            let harmonyMean = f.reduce(0) { $0 + $1.harmony } / 4
            let sectionMean = f.reduce(0) { $0 + $1.section } / 4
            // Slot s of this block is beat index k + s, whose phase is (k + s) mod 4 == s because k mod 4 == 0.
            scores.append((0..<4).map { p in
                let backbeat = (f[(p + 1) % 4].snare + f[(p + 3) % 4].snare - f[p].snare - f[(p + 2) % 4].snare) / 2
                return (f[p].kick - kickMean) + backbeat + (f[p].harmony - harmonyMean) + (f[p].section - sectionMean)
            })
        }
        guard scores.count >= minDownbeatBlocks else { return nil }

        func ranking(_ rows: [[Double]]) -> [Int] {
            let means = (0..<4).map { p in rows.reduce(0) { $0 + $1[p] } / Double(max(1, rows.count)) }
            return means.indices.sorted { means[$0] > means[$1] }
        }
        let order = ranking(scores)
        let best = order[0], second = order[1]
        let diffs = scores.map { $0[best] - $0[second] }
        let mean = diffs.reduce(0) { $0 + $1 } / Double(diffs.count)
        let variance = diffs.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(max(1, diffs.count - 1))
        let standardError = max(variance.squareRoot() / Double(diffs.count).squareRoot(), 1e-9)

        let half = scores.count / 2
        let splits: [[[Double]]] = [
            Array(scores[..<half]), Array(scores[half...]),
            scores.enumerated().filter { $0.offset % 2 == 0 }.map(\.element),
            scores.enumerated().filter { $0.offset % 2 == 1 }.map(\.element),
            Array(scores[..<(scores.count / 3)]), Array(scores[(scores.count / 3)..<(2 * scores.count / 3)]),
            Array(scores[(2 * scores.count / 3)...]),
        ]
        let picks = splits.map { ranking($0)[0] }
        let agrees = picks.allSatisfy { $0 == best }
        return DownbeatEstimate(
            phase: best, margin: mean / standardError, effect: mean, agrees: agrees, blocks: scores.count, splitPhases: picks
        )
    }

    // MARK: Features

    struct BeatFeature {
        var kick: Double
        var snare: Double
        var harmony: Double
        var section: Double
    }

    /// Per beat of `beats` (index k - beats.lowerBound), nil where the audio does not reach. Every feature is divided by
    /// its mean over the beats so that none dominates the score.
    static func beatFeatures(
        decimated: [Float], rate: Double, grid: MusicBeatGrid, beats: ClosedRange<Int>, band: Band
    ) -> [BeatFeature?] {
        let count = decimated.count
        let period = grid.periodSec
        let total = beats.count
        var kick = [Double?](repeating: nil, count: total)
        var snare = [Double?](repeating: nil, count: total)
        var harmony = [Double?](repeating: nil, count: total)
        var loudness = [Double?](repeating: nil, count: total)

        let chromaSpectrum = Spectrum(size: chromaWindow)
        let snareSpectrum = Spectrum(size: snareWindow)
        defer {
            chromaSpectrum.destroy()
            snareSpectrum.destroy()
        }
        for (offset, k) in beats.enumerated() {
            if offset % 32 == 0, Task.isCancelled { return [] }
            let t = grid.beatTime(k)
            let sample = Int((t * rate).rounded())
            guard sample >= 0, sample < count else { continue }

            // Kick: bass level and bass attack around the beat.
            let lo = Int(((t - 0.01) * rate).rounded()), hi = Int(((t + 0.05) * rate).rounded())
            if lo >= 0, hi < count {
                var level: Float = 0
                for index in lo...hi { level = max(level, band.env[index]) }
                var attack: Float = 0
                for index in max(0, lo - Int(0.02 * rate))...min(count - 1, hi) { attack = max(attack, band.flux[index]) }
                kick[offset] = Double(level) + Double(attack)
            }

            // Loudness of the beat's own span, for the section cue.
            let end = min(count, sample + Int(period * rate))
            if end - sample > Int(0.5 * period * rate) {
                var energy: Float = 0
                decimated.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + sample, 1, &energy, vDSP_Length(end - sample)) }
                loudness[offset] = Double(energy) / Double(end - sample)
            }

            // Snare: strongest rise of the mid band in the frames around the beat.
            snare[offset] = midRise(decimated, rate: rate, centre: t, spectrum: snareSpectrum)

            // Harmony: how different the pitch classes after the beat are from those before it.
            let afterStart = Int(((t + chromaGapAfterSec) * rate).rounded())
            let beforeStart = Int(((t - chromaGapBeforeSec) * rate).rounded()) - chromaWindow
            if beforeStart >= 0, afterStart + chromaWindow <= count {
                // A window with no tonal content (silence, a bare kick) tells nothing: no change is recorded.
                if let before = chroma(decimated, start: beforeStart, rate: rate, spectrum: chromaSpectrum),
                   let after = chroma(decimated, start: afterStart, rate: rate, spectrum: chromaSpectrum) {
                    var dot: Float = 0
                    vDSP_dotpr(before, 1, after, 1, &dot, 12)
                    harmony[offset] = Double(max(0, 1 - dot))
                } else {
                    harmony[offset] = 0
                }
            }
        }

        // Section novelty: |log loudness of the next beats - log loudness of the previous beats|.
        var section = [Double?](repeating: nil, count: total)
        let span = sectionBeats
        for offset in span..<max(span, total - span + 1) where offset + span <= total {
            let before = loudness[(offset - span)..<offset].compactMap { $0 }
            let after = loudness[offset..<(offset + span)].compactMap { $0 }
            guard before.count == span, after.count == span else { continue }
            let b = before.reduce(0, +) / Double(span), a = after.reduce(0, +) / Double(span)
            section[offset] = abs(log(a + 1e-9) - log(b + 1e-9))
        }

        func normalised(_ values: [Double?], floor: Double = 0) -> [Double?] {
            let present = values.compactMap { $0 }
            let mean = present.reduce(0, +) / Double(max(1, present.count))
            guard mean > 1e-12 else { return values.map { $0 == nil ? nil : 0 } }
            return values.map { $0.map { $0 / max(mean, floor) } }
        }
        let nk = normalised(kick), ns = normalised(snare)
        let nh = normalised(harmony, floor: harmonyFloor), nsec = normalised(section, floor: sectionFloor)
        return (0..<total).map { index in
            guard let a = nk[index], let b = ns[index], let c = nh[index] else { return nil }
            return BeatFeature(kick: a, snare: b, harmony: c, section: nsec[index] ?? 1)
        }
    }

    /// Largest summed rise of log mid-band magnitude between consecutive frames from 30 ms before to 60 ms after `centre`.
    private static func midRise(_ audio: [Float], rate: Double, centre: Double, spectrum: Spectrum) -> Double? {
        let size = spectrum.size
        let first = Int(((centre - 0.03) * rate).rounded()) - size / 2
        let frames = Int((0.09 * rate) / Double(snareHop)) + 2
        guard first - snareHop >= 0, first + (frames - 1) * snareHop + size <= audio.count else { return nil }
        let binHz = rate / Double(size)
        let lowBin = max(1, Int((snareLowHz / binHz).rounded())), highBin = min(size / 2 - 1, Int((snareHighHz / binHz).rounded()))
        guard lowBin < highBin else { return nil }
        var previous = spectrum.magnitudes(audio, start: first - snareHop)
        var best = 0.0
        for frame in 0..<frames {
            let current = spectrum.magnitudes(audio, start: first + frame * snareHop)
            var rise = 0.0
            for bin in lowBin...highBin {
                let d = log(1 + 100 * Double(current[bin])) - log(1 + 100 * Double(previous[bin]))
                if d > 0 { rise += d }
            }
            best = max(best, rise)
            previous = current
        }
        return best
    }

    /// Unit-length pitch-class profile of the window starting at `start`: spectral peaks between `chromaLowHz` and
    /// `chromaHighHz` (local maxima above 15% of the strongest), summed per semitone class. nil for a silent window.
    private static func chroma(_ audio: [Float], start: Int, rate: Double, spectrum: Spectrum) -> [Float]? {
        let magnitudes = spectrum.magnitudes(audio, start: start)
        let binHz = rate / Double(spectrum.size)
        let lowBin = max(2, Int((chromaLowHz / binHz).rounded())), highBin = min(spectrum.size / 2 - 2, Int((chromaHighHz / binHz).rounded()))
        guard lowBin < highBin else { return nil }
        var peak: Float = 0
        for bin in lowBin...highBin { peak = max(peak, magnitudes[bin]) }
        guard peak > 1e-6 else { return nil }
        var classes = [Float](repeating: 0, count: 12)
        for bin in lowBin...highBin where magnitudes[bin] >= 0.15 * peak
            && magnitudes[bin] >= magnitudes[bin - 1] && magnitudes[bin] > magnitudes[bin + 1] {
            let semitone = 12 * log2(Double(bin) * binHz / 440)
            let index = ((Int(semitone.rounded()) % 12) + 12 + 9) % 12
            classes[index] += magnitudes[bin]
        }
        var norm: Float = 0
        vDSP_svesq(classes, 1, &norm, 12)
        guard norm > 1e-12 else { return nil }
        var scale = 1 / norm.squareRoot()
        vDSP_vsmul(classes, 1, &scale, &classes, 1, 12)
        return classes
    }

    /// A Hann-windowed real FFT of fixed size.
    struct Spectrum {
        let size: Int
        private let setup: FFTSetup
        private let log2n: vDSP_Length
        private let window: [Float]

        init(size: Int) {
            self.size = size
            log2n = vDSP_Length(log2(Double(size)).rounded())
            setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
            var w = [Float](repeating: 0, count: size)
            vDSP_hann_window(&w, vDSP_Length(size), Int32(vDSP_HANN_NORM))
            window = w
        }

        func destroy() { vDSP_destroy_fftsetup(setup) }

        /// Magnitudes of bins 0..<size/2 for the window starting at `start` (the caller keeps it inside the audio).
        func magnitudes(_ audio: [Float], start: Int) -> [Float] {
            var frame = [Float](repeating: 0, count: size)
            audio.withUnsafeBufferPointer { vDSP_vmul($0.baseAddress! + start, 1, window, 1, &frame, 1, vDSP_Length(size)) }
            let half = size / 2
            var real = [Float](repeating: 0, count: half), imag = [Float](repeating: 0, count: half)
            var out = [Float](repeating: 0, count: half)
            real.withUnsafeMutableBufferPointer { r in
                imag.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    frame.withUnsafeBufferPointer { f in
                        f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    vDSP_zvabs(&split, 1, &out, 1, vDSP_Length(half))
                }
            }
            return out
        }
    }
}
