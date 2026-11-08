// Deci/Music/Analysis/MusicBeatFinder.swift
// Deci's own beat finder (tier 3a, part 2): a pure, synchronous function from mono samples to a tempo, a confidence and
// beat times. The shape is Ellis 2007 as laid out in librosa (ISC): decimate to about 22 kHz, log-mel STFT, half-wave
// rectified spectral flux as the onset envelope, autocorrelation tempo with a log-Gaussian prior, then dynamic
// programming beat tracking with a transition penalty on log(interval / period). All DSP is vDSP; nothing is copied
// from aubio, Essentia or madmom.
//
// The beat grid (MusicBeatFinderGrid.swift) refines this result on the bass band; the analysis decode loop feeds it.

import Foundation
import Accelerate

/// What the beat finder reports. An empty result (`bpm == 0`, no beats) means "no usable tempo".
nonisolated struct MusicBeatResult: Sendable, Equatable {
    /// Where bar starts fall, in 4/4: `phase` is the beat index (0...3, counting from `beats[0]`) of a bar start.
    struct Downbeat: Sendable, Equatable {
        var phase: Int
        /// 0 (no preference between the four phases) to 1 (one phase clearly carries the accents).
        var confidence: Double
    }

    /// Beats per minute, from a line fitted through the beat times (not the coarse autocorrelation lag).
    var bpm: Double
    /// 0 to 1: how regular the beat grid is and how strong the autocorrelation peak is.
    var confidence: Double
    /// Beat times in seconds from the first sample.
    var beats: [Double]
    /// Robust spread of the inter-beat intervals as a fraction of the median (1.4826 * MAD / median).
    var intervalSpread: Double
    /// nil when there were too few beats to say.
    var downbeat: Downbeat?

    static let empty = MusicBeatResult(bpm: 0, confidence: 0, beats: [], intervalSpread: 0, downbeat: nil)

    var isEmpty: Bool { bpm <= 0 || beats.isEmpty }
}

nonisolated enum MusicBeatFinder {
    // MARK: Parameters

    static let targetRate = 22_050.0
    static let fftSize = 1024
    /// Hop in seconds (256 samples at 22.05 kHz).
    static let hopSeconds = 256.0 / 22_050.0
    static let melBands = 48
    static let minBPM = 60.0
    static let maxBPM = 200.0
    /// The log-Gaussian prior sits at 125 BPM, not 120: with 120, a clean 174 BPM pulse loses to its half-time 87 and
    /// a clean 90 BPM pulse stays put; between 123 and 127 both come out right.
    /// Known limit: the tempo octave is the autocorrelation's call. A kick on beats 1 and 3 only reads as half time
    /// (150 as 75) and a busy 90 can read as 180; the grid is steady either way and the planner accepts it.
    static let priorCenterBPM = 125.0
    static let priorSigmaOctaves = 1.0
    /// Transition penalty weight of the beat tracker (librosa uses 100).
    static let tightness = 100.0
    /// How much of the bass-band flux is added to the broadband flux.
    static let bassWeight = 1.0
    /// Shorter input than this has too few beats to track.
    static let minSeconds = 4.0

    // MARK: Entry point

    /// `samples` are mono at `sampleRate`. Silence, non-finite input or less than `minSeconds` of audio give `.empty`.
    static func analyze(samples: [Float], sampleRate: Double) -> MusicBeatResult {
        guard sampleRate.isFinite, sampleRate >= 8_000, Double(samples.count) >= minSeconds * sampleRate else { return .empty }
        guard let (audio, rate) = decimate(samples, sampleRate: sampleRate) else { return .empty }
        return analyze(decimated: audio, rate: rate)
    }

    /// The same, from audio already decimated to about 22 kHz (`MusicBeatDecimator`).
    static func analyze(decimated audio: [Float], rate: Double) -> MusicBeatResult {
        guard rate.isFinite, rate >= 8_000, Double(audio.count) >= minSeconds * rate else { return .empty }
        guard let envelopes = onsetEnvelopes(audio, rate: rate) else { return .empty }
        let frameRate = rate / Double(envelopes.hop)
        // Broadband flux plus the bass bands: a bass drum touches few mel bands, a hat touches many, and log flux makes
        // them equal. Weighting the bass keeps the beat grid on the kick instead of the off-beat hat.
        var env = envelopes.full
        vDSP_vsma(envelopes.low, 1, [Float(bassWeight)], env, 1, &env, 1, vDSP_Length(env.count))
        guard let tempo = estimateTempo(env, frameRate: frameRate) else { return .empty }

        let normalised = normalisedByDeviation(env)
        let local = localScore(normalised, period: tempo.period)
        let frames = trimByOnsetStrength(trackBeats(local: local, period: tempo.period), env: env)
        guard frames.count >= 4 else { return .empty }

        // Sub-frame times. A frame's flux belongs to the onset about `latency` frames before its centre.
        let times = frames.map { refinedTime(frame: $0, env: env, frameRate: frameRate) }
        guard let fit = fitGrid(times) else { return .empty }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }
        let spread = robustSpread(intervals)
        let within = intervals.filter { abs($0 / fit.period - 1) < 0.08 }.count
        let regularity = Double(within) / Double(max(1, intervals.count))
        let strength = min(1, max(0, tempo.peak / 0.5))
        let confidence = min(1, max(0, 0.5 * regularity + 0.5 * strength))
        let bpm = 60 / fit.period
        guard bpm.isFinite, bpm > 0, times.allSatisfy(\.isFinite) else { return .empty }

        let downbeat = estimateDownbeat(frames: frames, low: envelopes.low, full: env)
        return MusicBeatResult(bpm: bpm, confidence: confidence, beats: times, intervalSpread: spread, downbeat: downbeat)
    }

    // MARK: 1. Decimation

    /// Lowpass and keep every `factor`-th sample, aiming at 22.05 kHz (44.1 and 48 kHz both use 2). nil for non-finite input.
    static func decimate(_ samples: [Float], sampleRate: Double) -> ([Float], Double)? {
        var sum: Float = 0
        samples.withUnsafeBufferPointer { vDSP_svemg($0.baseAddress!, 1, &sum, vDSP_Length($0.count)) }
        guard sum.isFinite else { return nil }
        let factor = max(1, Int((sampleRate / targetRate).rounded()))
        if factor == 1 { return (samples, sampleRate) }

        let taps = 16 * factor + 1
        let cutoff = 0.45 / Double(factor)
        var filter = [Float](repeating: 0, count: taps)
        var total: Float = 0
        let mid = Double(taps - 1) / 2
        for index in 0..<taps {
            let x = Double(index) - mid
            let sinc = x == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * x) / (Double.pi * x)
            let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(index) / Double(taps - 1))
            filter[index] = Float(sinc * hann)
            total += filter[index]
        }
        for index in 0..<taps { filter[index] /= total }

        let half = (taps - 1) / 2
        let outCount = samples.count / factor
        guard outCount > 0 else { return nil }
        var padded = [Float](repeating: 0, count: half + samples.count + taps)
        padded.replaceSubrange(half..<(half + samples.count), with: samples)
        var out = [Float](repeating: 0, count: outCount)
        padded.withUnsafeBufferPointer { input in
            vDSP_desamp(input.baseAddress!, vDSP_Stride(factor), filter, &out, vDSP_Length(outCount), vDSP_Length(taps))
        }
        return (out, sampleRate / Double(factor))
    }

    // MARK: 2. Onset envelope

    struct Envelopes {
        /// Mean over all mel bands of the half-wave rectified log-mel difference, one value per frame.
        var full: [Float]
        /// The same over the lowest bands only (kick and bass): the downbeat cue.
        var low: [Float]
        var hop: Int
    }

    /// Log-mel spectral flux. nil when the signal is digital silence.
    static func onsetEnvelopes(_ audio: [Float], rate: Double) -> Envelopes? {
        let n = fftSize
        let hop = max(1, Int((hopSeconds * rate).rounded()))
        let bands = melBands
        let bins = n / 2
        guard audio.count > n else { return nil }
        let frameCount = audio.count / hop + 1

        // Reflect-padded copy so frame t is centred on sample t * hop.
        let pad = n / 2
        var padded = [Float](repeating: 0, count: audio.count + 2 * pad)
        padded.replaceSubrange(pad..<(pad + audio.count), with: audio)
        for index in 0..<pad {
            padded[pad - 1 - index] = audio[min(audio.count - 1, index + 1)]
            padded[pad + audio.count + index] = audio[max(0, audio.count - 2 - index)]
        }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        let bank = melFilterbank(rate: rate, bins: bins, bands: bands)

        guard let setup = vDSP_create_fftsetup(vDSP_Length(log2(Double(n))), FFTRadix(kFFTRadix2)) else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        var mel = [Float](repeating: 0, count: frameCount * bands)
        let chunk = 256
        var frame = [Float](repeating: 0, count: n)
        var real = [Float](repeating: 0, count: bins)
        var imag = [Float](repeating: 0, count: bins)
        var power = [Float](repeating: 0, count: chunk * bins)
        var start = 0
        while start < frameCount {
            let count = min(chunk, frameCount - start)
            for row in 0..<count {
                let offset = (start + row) * hop
                padded.withUnsafeBufferPointer { src in
                    window.withUnsafeBufferPointer { win in
                        vDSP_vmul(src.baseAddress! + offset, 1, win.baseAddress!, 1, &frame, 1, vDSP_Length(n))
                    }
                }
                real.withUnsafeMutableBufferPointer { re in
                    imag.withUnsafeMutableBufferPointer { im in
                        var split = DSPSplitComplex(realp: re.baseAddress!, imagp: im.baseAddress!)
                        frame.withUnsafeBufferPointer { f in
                            f.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: bins) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(bins)) }
                        }
                        vDSP_fft_zrip(setup, &split, 1, vDSP_Length(log2(Double(n))), FFTDirection(FFT_FORWARD))
                        // zrip packs Nyquist into imag[0]; drop it, it carries nothing a beat needs.
                        im[0] = 0
                        power.withUnsafeMutableBufferPointer { p in
                            vDSP_zvmags(&split, 1, p.baseAddress! + row * bins, 1, vDSP_Length(bins))
                        }
                    }
                }
            }
            // [count x bins] times [bins x bands] -> [count x bands]
            mel.withUnsafeMutableBufferPointer { out in
                vDSP_mmul(power, 1, bank, 1, out.baseAddress! + start * bands, 1, vDSP_Length(count), vDSP_Length(bands), vDSP_Length(bins))
            }
            start += count
        }

        var peak: Float = 0
        vDSP_maxv(mel, 1, &peak, vDSP_Length(mel.count))
        // Under the smallest normal float 1 / peak overflows to infinity and fills the log with NaN.
        guard peak.isFinite, peak > Float.leastNormalMagnitude else { return nil }

        // Power to dB relative to the loudest cell, floored at -80 dB.
        var scaled = [Float](repeating: 0, count: mel.count)
        var inversePeak = 1 / peak
        vDSP_vsmul(mel, 1, &inversePeak, &scaled, 1, vDSP_Length(mel.count))
        var one: Float = 1, floorRatio: Float = 1e-8
        vDSP_vclip(scaled, 1, &floorRatio, &one, &scaled, 1, vDSP_Length(scaled.count))
        var logged = scaled
        var count32 = Int32(scaled.count)
        vvlog10f(&logged, scaled, &count32)
        var ten: Float = 10
        vDSP_vsmul(logged, 1, &ten, &logged, 1, vDSP_Length(logged.count))

        var full = [Float](repeating: 0, count: frameCount)
        var low = [Float](repeating: 0, count: frameCount)
        let lowBands = max(1, bands / 5)
        var diff = [Float](repeating: 0, count: bands)
        let zero: Float = 0
        for t in 1..<frameCount {
            logged.withUnsafeBufferPointer { l in
                vDSP_vsub(l.baseAddress! + (t - 1) * bands, 1, l.baseAddress! + t * bands, 1, &diff, 1, vDSP_Length(bands))
            }
            var rectified = diff
            var threshold = zero
            vDSP_vthr(diff, 1, &threshold, &rectified, 1, vDSP_Length(bands))
            var total: Float = 0, lowTotal: Float = 0
            vDSP_sve(rectified, 1, &total, vDSP_Length(bands))
            vDSP_sve(rectified, 1, &lowTotal, vDSP_Length(lowBands))
            full[t] = total / Float(bands)
            low[t] = lowTotal / Float(lowBands)
        }
        return Envelopes(full: full, low: low, hop: hop)
    }

    /// Triangular mel filters, row-major [bins x bands] so a power frame multiplies straight into it.
    static func melFilterbank(rate: Double, bins: Int, bands: Int) -> [Float] {
        func mel(_ hz: Double) -> Double { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Double) -> Double { 700 * (pow(10, mel / 2595) - 1) }
        let fmin = 30.0, fmax = rate / 2
        let lo = mel(fmin), hi = mel(fmax)
        let edges = (0...(bands + 1)).map { hz(lo + (hi - lo) * Double($0) / Double(bands + 1)) }
        var bank = [Float](repeating: 0, count: bins * bands)
        let binWidth = rate / Double(2 * bins)
        for band in 0..<bands {
            let left = edges[band], centre = edges[band + 1], right = edges[band + 2]
            for bin in 0..<bins {
                let f = Double(bin) * binWidth
                var weight = 0.0
                if f > left && f <= centre { weight = (f - left) / (centre - left) }
                else if f > centre && f < right { weight = (right - f) / (right - centre) }
                bank[bin * bands + band] = Float(weight)
            }
        }
        return bank
    }

    static func normalisedByDeviation(_ env: [Float]) -> [Float] {
        var mean: Float = 0, deviation: Float = 0
        vDSP_normalize(env, 1, nil, 1, &mean, &deviation, vDSP_Length(env.count))
        guard deviation.isFinite, deviation > 1e-9 else { return env }
        var scale = 1 / deviation
        var out = env
        vDSP_vsmul(env, 1, &scale, &out, 1, vDSP_Length(env.count))
        return out
    }

    // MARK: 3. Tempo

    struct Tempo {
        /// Beat period in frames (fractional).
        var period: Double
        /// Normalised autocorrelation at the chosen lag, 0...1.
        var peak: Double
    }

    /// Autocorrelation of the mean-removed envelope over the lags of 60 to 200 BPM (plus the 2x lag, which backs a lag up
    /// when the beat lands on every other onset), weighted by a log-Gaussian prior. nil when there is no structure.
    static func estimateTempo(_ env: [Float], frameRate: Double) -> Tempo? {
        let count = env.count
        let minLag = Int(floor(frameRate * 60 / maxBPM))
        let maxLag = Int(ceil(frameRate * 60 / minBPM))
        guard count > 4 * maxLag, minLag >= 2 else { return nil }

        var mean: Float = 0
        vDSP_meanv(env, 1, &mean, vDSP_Length(count))
        var negative = -mean
        var centred = [Float](repeating: 0, count: count)
        vDSP_vsadd(env, 1, &negative, &centred, 1, vDSP_Length(count))
        var energy: Float = 0
        vDSP_dotpr(centred, 1, centred, 1, &energy, vDSP_Length(count))
        guard energy > 1e-9 else { return nil }

        let top = 2 * maxLag + 1
        var acf = [Double](repeating: 0, count: top + 2)
        for lag in 1...(top + 1) where lag < count {
            var dot: Float = 0
            centred.withUnsafeBufferPointer { c in
                vDSP_dotpr(c.baseAddress!, 1, c.baseAddress! + lag, 1, &dot, vDSP_Length(count - lag))
            }
            // Unbiased: divide by the overlap, then by the lag-0 power.
            acf[lag] = Double(dot) / Double(count - lag) / (Double(energy) / Double(count))
        }

        func value(at lag: Double) -> Double {
            let lower = Int(floor(lag))
            guard lower >= 1, lower + 1 < acf.count else { return 0 }
            let fraction = lag - Double(lower)
            return acf[lower] * (1 - fraction) + acf[lower + 1] * fraction
        }

        var best: (score: Double, lag: Int)?
        for lag in minLag...maxLag {
            let bpm = frameRate * 60 / Double(lag)
            let octaves = log2(bpm / priorCenterBPM) / priorSigmaOctaves
            let prior = exp(-0.5 * octaves * octaves)
            let support = max(0, acf[lag]) + 0.5 * max(0, acf[min(2 * lag, acf.count - 1)])
            let score = support * prior
            if best == nil || score > best!.score { best = (score, lag) }
        }
        guard let chosen = best, chosen.score > 0 else { return nil }

        // Parabolic refinement of the peak lag.
        var lag = Double(chosen.lag)
        if chosen.lag > 1 {
            let a = acf[chosen.lag - 1], b = acf[chosen.lag], c = acf[chosen.lag + 1]
            let denominator = a - 2 * b + c
            if denominator < -1e-12 { lag += max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return Tempo(period: lag, peak: max(0, min(1, acf[chosen.lag])))
    }

    // MARK: 4. Beat tracking

    /// The envelope smoothed by a Gaussian about a beat period wide (librosa's local score).
    static func localScore(_ env: [Float], period: Double) -> [Float] {
        let radius = max(1, Int(period.rounded()))
        let kernel: [Float] = (-radius...radius).map { offset in
            let x = Double(offset) * 32 / period
            return Float(exp(-0.5 * x * x))
        }
        let count = env.count
        var padded = [Float](repeating: 0, count: count + 2 * radius)
        padded.replaceSubrange(radius..<(radius + count), with: env)
        var out = [Float](repeating: 0, count: count)
        // vDSP_conv correlates; the kernel is symmetric so that is the convolution.
        padded.withUnsafeBufferPointer { p in
            vDSP_conv(p.baseAddress!, 1, kernel, 1, &out, 1, vDSP_Length(count), vDSP_Length(kernel.count))
        }
        return out
    }

    /// Dynamic programming over beat positions, then backtracking from the last strong local maximum. Returns frames.
    static func trackBeats(local: [Float], period: Double) -> [Int] {
        let count = local.count
        guard count > 0, period >= 2 else { return [] }
        var maxLocal: Float = 0
        vDSP_maxv(local, 1, &maxLocal, vDSP_Length(count))
        guard maxLocal > 0 else { return [] }

        let nearest = max(1, Int((period / 2).rounded(.up)))
        let farthest = max(nearest + 1, Int((2 * period).rounded()))
        // penalty[d] for a gap of d frames.
        var penalty = [Float](repeating: 0, count: farthest + 1)
        for gap in nearest...farthest {
            let ratio = log(Double(gap) / period)
            penalty[gap] = Float(-tightness * ratio * ratio)
        }

        var cumulative = [Float](repeating: 0, count: count)
        var backlink = [Int](repeating: -1, count: count)
        for i in 0..<count {
            var bestScore = -Float.infinity
            var bestFrom = -1
            let lowest = max(0, i - farthest)
            let highest = i - nearest
            if highest >= lowest {
                for j in lowest...highest {
                    let candidate = cumulative[j] + penalty[i - j]
                    if candidate > bestScore { bestScore = candidate; bestFrom = j }
                }
            }
            // A beat may also start a chain (no predecessor, no penalty): librosa charges the first beat a full interval
            // penalty against whatever junk precedes it, which pushes the true first beat out.
            if bestFrom >= 0 && bestScore > 0 {
                cumulative[i] = local[i] + bestScore
                backlink[i] = bestFrom
            } else {
                cumulative[i] = local[i]
                backlink[i] = -1
            }
        }

        // Last beat: the final local maximum of the cumulative score at least half the median maximum.
        var maxima: [Int] = []
        for i in 1..<max(1, count - 1) where cumulative[i] > cumulative[i - 1] && cumulative[i] >= cumulative[i + 1] {
            maxima.append(i)
        }
        guard !maxima.isEmpty else { return [] }
        let sortedValues = maxima.map { cumulative[$0] }.sorted()
        let median = sortedValues[sortedValues.count / 2]
        let threshold = 0.5 * median
        guard let last = maxima.last(where: { cumulative[$0] >= threshold }) else { return [] }

        var beats = [last]
        while backlink[beats[beats.count - 1]] >= 0 { beats.append(backlink[beats[beats.count - 1]]) }
        beats.reverse()
        return trim(beats: beats, local: local)
    }

    /// Drops weak beats at both ends: smooth the local score at the beats with a 5 point Hann window and cut while it
    /// sits under half its RMS.
    static func trim(beats: [Int], local: [Float]) -> [Int] {
        guard beats.count > 5 else { return beats }
        let strengths = beats.map { local[$0] }
        let hann: [Float] = [0.25, 0.75, 1, 0.75, 0.25].map { $0 * 0.5 }
        var smooth = [Float](repeating: 0, count: strengths.count)
        for index in strengths.indices {
            // Edge beats have fewer neighbours: normalise by the weight actually inside the list.
            var sum: Float = 0, weights: Float = 0
            for (offset, weight) in hann.enumerated() {
                let at = index + offset - 2
                if at >= 0 && at < strengths.count { sum += strengths[at] * weight; weights += weight }
            }
            smooth[index] = sum / weights * 1.5
        }
        var meanSquare: Float = 0
        vDSP_measqv(smooth, 1, &meanSquare, vDSP_Length(smooth.count))
        let threshold = 0.5 * meanSquare.squareRoot()
        var lo = 0, hi = beats.count
        while lo < hi, smooth[lo] <= threshold { lo += 1 }
        while hi > lo, smooth[hi - 1] <= threshold { hi -= 1 }
        return Array(beats[lo..<hi])
    }

    /// Second edge trim on the raw envelope: a beat at either end needs an onset peak (within 2 frames) of at least 30%
    /// of the median beat's. The smoothed score alone lets a ghost beat one period before the first onset survive.
    static func trimByOnsetStrength(_ beats: [Int], env: [Float]) -> [Int] {
        guard beats.count > 5 else { return beats }
        let strengths: [Float] = beats.map { beat in
            let lo = max(0, beat - 2), hi = min(env.count - 1, beat + 2)
            return env[lo...hi].max() ?? 0
        }
        let threshold = 0.3 * strengths.sorted()[strengths.count / 2]
        var lo = 0, hi = beats.count
        while lo < hi, strengths[lo] < threshold { lo += 1 }
        while hi > lo, strengths[hi - 1] < threshold { hi -= 1 }
        return Array(beats[lo..<hi])
    }

    // MARK: Beat times

    /// Frames are centred on their hop, and log-compressed flux fires as soon as the trailing edge of a window touches an
    /// attack, so the envelope peak lands about a frame before the attack itself. Measured on synthetic kicks over
    /// silence (the extreme case; with a dense mix the lead is smaller): 0.954 frames, 11 ms.
    static let leadFrames = 0.954

    static func refinedTime(frame: Int, env: [Float], frameRate: Double) -> Double {
        var best = frame
        let lo = max(1, frame - 2), hi = min(env.count - 2, frame + 2)
        if lo <= hi {
            for index in lo...hi where env[index] > env[best] { best = index }
        }
        var position = Double(best)
        if best >= 1, best + 1 < env.count {
            let a = Double(env[best - 1]), b = Double(env[best]), c = Double(env[best + 1])
            let denominator = a - 2 * b + c
            if denominator < -1e-12 { position += max(-0.5, min(0.5, 0.5 * (a - c) / denominator)) }
        }
        return (position + leadFrames) / frameRate
    }

    /// Least squares line t = a + period * k through the beats, with k the rounded beat number and two rounds of
    /// outlier rejection. nil when the beats do not form a grid.
    static func fitGrid(_ times: [Double]) -> (start: Double, period: Double)? {
        guard times.count >= 3 else { return nil }
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.sorted()
        var period = intervals[intervals.count / 2]
        guard period > 0 else { return nil }
        var start = times[0]
        var kept = Array(times.indices)
        var indices = [Double](repeating: 0, count: times.count)
        for _ in 0..<3 {
            indices = times.map { ($0 - start) / period }.map { $0.rounded() }
            var sumK = 0.0, sumT = 0.0, sumKK = 0.0, sumKT = 0.0
            var n = 0.0
            for i in kept {
                let k = indices[i], t = times[i]
                sumK += k; sumT += t; sumKK += k * k; sumKT += k * t; n += 1
            }
            let denominator = n * sumKK - sumK * sumK
            guard n >= 3, abs(denominator) > 1e-9 else { break }
            let slope = (n * sumKT - sumK * sumT) / denominator
            guard slope > 0 else { return nil }
            period = slope
            start = (sumT - slope * sumK) / n
            kept = times.indices.filter { abs(times[$0] - (start + period * indices[$0])) < 0.25 * period }
            if kept.count < 3 { return nil }
        }
        return (start, period)
    }

    static func robustSpread(_ intervals: [Double]) -> Double {
        guard intervals.count >= 2 else { return 0 }
        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        guard median > 0 else { return 0 }
        let deviations = intervals.map { abs($0 - median) }.sorted()
        return 1.4826 * deviations[deviations.count / 2] / median
    }

    // MARK: Downbeat (experimental)

    /// Which of four beat phases carries the accents: the mean of the bass flux plus the full flux at each beat, per
    /// phase. Unvalidated on real songs; needs 16 beats.
    static func estimateDownbeat(frames: [Int], low: [Float], full: [Float]) -> MusicBeatResult.Downbeat? {
        guard frames.count >= 16 else { return nil }
        var sums = [Double](repeating: 0, count: 4)
        var counts = [Double](repeating: 0, count: 4)
        for (index, frame) in frames.enumerated() {
            let lo = max(0, frame - 1), hi = min(low.count - 1, frame + 1)
            var strength = 0.0
            for i in lo...hi { strength = max(strength, Double(low[i]) + 0.5 * Double(full[i])) }
            sums[index % 4] += strength
            counts[index % 4] += 1
        }
        let means = (0..<4).map { counts[$0] > 0 ? sums[$0] / counts[$0] : 0 }
        guard let best = means.indices.max(by: { means[$0] < means[$1] }), means[best] > 0 else { return nil }
        let others = (0..<4).filter { $0 != best }.map { means[$0] }
        let otherMean = others.reduce(0, +) / Double(others.count)
        let confidence = max(0, min(1, (means[best] - otherMean) / means[best]))
        return MusicBeatResult.Downbeat(phase: best, confidence: confidence)
    }
}
