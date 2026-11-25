// Deci/Music/Playback/MusicMixEQ.swift
// The mids and highs of a deck's three band mixer EQ (the lows are the bass channel, `MusicBassSplit`). Two shelves in
// series, a low shelf at 160 Hz and a high shelf at 3.5 kHz, around a mid gain: the lows always come out at 1, the mids at
// `mid` and the highs at `high`. Every gain is a cut, so the result is never louder than the signal that went in. The shelves
// are the trapezoidal state-variable form (stable while their gain moves) with their state in Double. With both gains at 1
// the output is the input, bit for bit, so the EQ can be switched on and off mid song without a click.
//
// `begin`, `release` and `end` are for any thread; `process` and `skip` are the render thread's. Everything is allocated once
// with the lease. Render safe: no lock, no allocation, no Objective-C.

import Foundation
import Synchronization

/// Where a band's gain is at a frame. Between two points the gain moves evenly in decibels, like a knob.
nonisolated struct MusicMixEQPoint: Equatable, Sendable {
    /// Rendered frames since the EQ was begun.
    var frame: Int
    /// 1 is untouched, smaller is a cut.
    var gain: Float
}

/// The moves of one deck through a mix. A band without points stays untouched.
nonisolated struct MusicMixEQSettings: Equatable, Sendable {
    /// The most points a band may have; later ones are dropped.
    static let maxPoints = 12
    /// The deepest cut, -26 dB.
    static let floorGain: Float = 0.05

    var mid: [MusicMixEQPoint] = []
    var high: [MusicMixEQPoint] = []

    static func clamped(_ gain: Float) -> Float {
        gain.isFinite ? min(1, max(floorGain, gain)) : 1
    }
}

nonisolated final class MusicMixEQ: @unchecked Sendable {
    static let lowCornerHz = 160.0
    static let highCornerHz = 3_500.0
    /// The longest stretch of frames one coefficient set is held for.
    static let blockFrames = 16
    private static let damping = 2.0.squareRoot()

    // MARK: Request (any thread writes, the renderer reads)

    private let activeFlag = Atomic<Bool>(false)
    private let generation = Atomic<Int>(0)
    private let releaseGeneration = Atomic<Int>(0)
    private let releaseFrames = Atomic<Int>(1)
    /// `releaseGeneration` as the last `begin` found it.
    private let releaseBase = Atomic<Int>(0)
    private let counts = Atomic<Int>(0)
    /// Two bands of `maxPoints`, each a frame (high word) and a gain's bits (low word).
    private let requested: UnsafeMutablePointer<Atomic<UInt64>>

    // MARK: Renderer state

    private let points: UnsafeMutablePointer<MusicMixEQPoint>
    private let tanLow: Double
    private let tanHigh: Double
    private var midCount = 0
    private var highCount = 0
    private var seenGeneration = 0
    private var seenReleaseGeneration = 0
    private var position = 0
    private var ran = false
    /// Nothing is left to do for this request: both bands are open and stay open.
    private var finished = true
    private var midLog = 0.0
    private var highLog = 0.0
    private var releasing = false
    private var releasePosition = 0
    private var releaseLength = 1
    private var releaseMidLog = 0.0
    private var releaseHighLog = 0.0
    /// Low shelf then high shelf, left then right, two integrators each.
    private var state = SIMD8<Double>(repeating: 0)

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        tanLow = tan(Double.pi * min(Self.lowCornerHz, rate * 0.2) / rate)
        tanHigh = tan(Double.pi * min(Self.highCornerHz, rate * 0.4) / rate)
        let capacity = MusicMixEQSettings.maxPoints * 2
        requested = .allocate(capacity: capacity)
        for index in 0..<capacity { (requested + index).initialize(to: Atomic<UInt64>(0)) }
        points = .allocate(capacity: capacity)
        points.initialize(repeating: MusicMixEQPoint(frame: 0, gain: 1), count: capacity)
    }

    deinit {
        let capacity = MusicMixEQSettings.maxPoints * 2
        requested.deinitialize(count: capacity)
        requested.deallocate()
        points.deallocate()
    }

    // MARK: Control (any thread)

    /// Starts the moves from the next render. A later call replaces the one in progress.
    func begin(_ settings: MusicMixEQSettings) {
        let most = MusicMixEQSettings.maxPoints
        let mids = settings.mid.prefix(most), highs = settings.high.prefix(most)
        for (index, point) in mids.enumerated() { store(point, at: index) }
        for (index, point) in highs.enumerated() { store(point, at: most + index) }
        counts.store(mids.count << 8 | highs.count, ordering: .relaxed)
        releaseBase.store(releaseGeneration.load(ordering: .relaxed), ordering: .relaxed)
        // Generation first, flag second, like the sweep: a renderer that sees the flag also sees the new generation.
        generation.wrappingAdd(1, ordering: .releasing)
        activeFlag.store(true, ordering: .releasing)
    }

    private func store(_ point: MusicMixEQPoint, at index: Int) {
        let frame = UInt64(UInt32(clamping: point.frame))
        requested[index].store(frame << 32 | UInt64(MusicMixEQSettings.clamped(point.gain).bitPattern), ordering: .relaxed)
    }

    /// Opens both bands from wherever they are over `frames` rendered frames; after that the EQ costs nothing.
    func release(frames: Int) {
        releaseFrames.store(max(1, frames), ordering: .relaxed)
        releaseGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// The EQ is off at the next render (the lease is about to be released).
    func end() { activeFlag.store(false, ordering: .releasing) }

    var isActive: Bool { activeFlag.load(ordering: .acquiring) }

    #if DEBUG
    /// What the last `begin` and `release` asked for, for the tests (the request, not the renderer's state).
    struct DebugRequest: Equatable, Sendable {
        var active: Bool
        var generation: Int
        var releases: Int
        var releaseFrames: Int
        var settings: MusicMixEQSettings
    }

    var debugRequest: DebugRequest {
        let count = counts.load(ordering: .relaxed)
        func band(_ offset: Int, _ count: Int) -> [MusicMixEQPoint] { (0..<count).map { load(offset + $0) } }
        return DebugRequest(
            active: isActive, generation: generation.load(ordering: .relaxed),
            releases: releaseGeneration.load(ordering: .relaxed), releaseFrames: releaseFrames.load(ordering: .relaxed),
            settings: MusicMixEQSettings(mid: band(0, count >> 8), high: band(MusicMixEQSettings.maxPoints, count & 0xFF))
        )
    }

    /// The gains the renderer last used.
    var debugGains: (mid: Double, high: Double) { (exp(midLog), exp(highLog)) }
    #endif

    private func load(_ index: Int) -> MusicMixEQPoint {
        let bits = requested[index].load(ordering: .relaxed)
        return MusicMixEQPoint(frame: Int(bits >> 32), gain: Float(bitPattern: UInt32(bits & 0xFFFF_FFFF)))
    }

    // MARK: Render thread

    /// Picks up a new request. True while there is something to do.
    private func pickUp() -> Bool {
        guard activeFlag.load(ordering: .acquiring) else {
            if ran { forget() }
            return false
        }
        let latest = generation.load(ordering: .acquiring)
        if latest != seenGeneration {
            seenGeneration = latest
            // A release asked for before this begin belongs to the request it replaces; one asked for since, before this
            // first render, is taken below.
            seenReleaseGeneration = releaseBase.load(ordering: .relaxed)
            let most = MusicMixEQSettings.maxPoints
            let count = counts.load(ordering: .relaxed)
            midCount = min(count >> 8, most)
            highCount = min(count & 0xFF, most)
            for index in 0..<midCount { points[index] = load(index) }
            for index in 0..<highCount { points[most + index] = load(most + index) }
            position = 0
            releasing = false
            finished = false
            state = SIMD8<Double>(repeating: 0)
            (midLog, highLog) = logs(at: 0)
        }
        let release = releaseGeneration.load(ordering: .acquiring)
        if release != seenReleaseGeneration {
            seenReleaseGeneration = release
            releasing = true
            releasePosition = 0
            releaseLength = releaseFrames.load(ordering: .relaxed)
            releaseMidLog = midLog
            releaseHighLog = highLog
        }
        ran = true
        return !finished
    }

    private func forget() {
        ran = false
        finished = true
        releasing = false
        midLog = 0
        highLog = 0
        state = SIMD8<Double>(repeating: 0)
    }

    /// ln of a band's gain `frame` frames in: even in decibels between the points, held before the first and after the last.
    private func log(band offset: Int, count: Int, at frame: Int) -> Double {
        guard count > 0 else { return 0 }
        let first = points[offset]
        if frame <= first.frame { return Foundation.log(Double(first.gain)) }
        var index = 1
        while index < count {
            let next = points[offset + index]
            if frame < next.frame {
                let before = points[offset + index - 1]
                let span = Double(max(1, next.frame - before.frame))
                let from = Foundation.log(Double(before.gain)), to = Foundation.log(Double(next.gain))
                return from + (to - from) * Double(frame - before.frame) / span
            }
            index += 1
        }
        return Foundation.log(Double(points[offset + count - 1].gain))
    }

    private func logs(at frame: Int) -> (Double, Double) {
        (log(band: 0, count: midCount, at: frame), log(band: MusicMixEQSettings.maxPoints, count: highCount, at: frame))
    }

    /// Moves the clock on by `run` frames and takes the gains of the middle of them.
    private func advance(_ run: Int) {
        if releasing {
            let left = max(0, 1 - (Double(releasePosition) + Double(run) / 2) / Double(releaseLength))
            midLog = releaseMidLog * left
            highLog = releaseHighLog * left
            releasePosition += run
            if releasePosition >= releaseLength { finished = true }
        } else {
            (midLog, highLog) = logs(at: position + run / 2)
            if midLog == 0, highLog == 0, pointsArePast(position) { finished = true }
        }
        position += run
        if finished {
            midLog = 0
            highLog = 0
        }
    }

    /// True when no point lies ahead of `frame`, so the gains never move again.
    private func pointsArePast(_ frame: Int) -> Bool {
        let most = MusicMixEQSettings.maxPoints
        return (midCount == 0 || points[midCount - 1].frame <= frame) && (highCount == 0 || points[most + highCount - 1].frame <= frame)
    }

    /// Keeps the moves in time through frames that are silenced anyway.
    func skip(_ frames: Int) {
        guard frames > 0, pickUp() else { return }
        state = SIMD8<Double>(repeating: 0)
        advance(frames)
    }

    /// Runs the EQ over a stereo interleaved block in place.
    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        guard pickUp() else { return }
        var done = 0
        while done < frames, !finished {
            let run = min(Self.blockFrames, frames - done)
            advance(run)
            if finished { break }
            filter(samples + done * 2, frames: run)
            done += run
        }
        if finished { state = SIMD8<Double>(repeating: 0) }
    }

    private func filter(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let k = Self.damping
        let mid = exp(midLog)
        // The low shelf takes the mids' cut back out of the lows, the high shelf leads the mids' gain over to the highs'.
        let lowA = exp(-midLog / 2), highA = exp((highLog - midLog) / 2)
        let lowG = tanLow / lowA.squareRoot(), highG = tanHigh * highA.squareRoot()
        let low1 = 1 / (1 + lowG * (lowG + k)), low2 = lowG * low1, low3 = lowG * low2
        let high1 = 1 / (1 + highG * (highG + k)), high2 = highG * high1, high3 = highG * high2
        let lowBand = k * (lowA - 1), lowPass = lowA * lowA - 1
        let highDry = highA * highA, highBand = k * (1 - highA) * highA, highPass = 1 - highA * highA
        for frame in 0..<frames {
            for channel in 0..<2 {
                let at = frame * 2 + channel, s = channel * 4
                let x = Double(samples[at])
                let lv3 = x - state[s + 1]
                let lv1 = low1 * state[s] + low2 * lv3
                let lv2 = state[s + 1] + low2 * state[s] + low3 * lv3
                state[s] = 2 * lv1 - state[s]
                state[s + 1] = 2 * lv2 - state[s + 1]
                let shelved = x + lowBand * lv1 + lowPass * lv2
                let hv3 = shelved - state[s + 3]
                let hv1 = high1 * state[s + 2] + high2 * hv3
                let hv2 = state[s + 3] + high2 * state[s + 2] + high3 * hv3
                state[s + 2] = 2 * hv1 - state[s + 2]
                state[s + 3] = 2 * hv2 - state[s + 3]
                var y = mid * (highDry * shelved + highBand * hv1 + highPass * hv2)
                if !y.isFinite {
                    // A broken input never leaves the filters in a bad state.
                    for index in s..<(s + 4) { state[index] = 0 }
                    y = 0
                }
                samples[at] = Float(y)
            }
        }
        // Denormals out, once per stretch.
        for index in 0..<8 where abs(state[index]) < 1e-20 { state[index] = 0 }
    }
}
