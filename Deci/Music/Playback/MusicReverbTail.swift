// Deci/Music/Playback/MusicReverbTail.swift
// The reverb out: the song is cut and hangs in the air. Eight damped comb filters and two allpasses per channel, allocated
// once with the lease. They are not fed while the song plays: at the cut the combs are filled in one go with what they would
// hold had they been fed for the last second (the sum of the echo line's history, one comb length apart, each a bit
// quieter), so an effect nobody asked for costs nothing. From the cut on they only recirculate, high-passed so the tail
// never fights the new song's bass. Render safe: no lock, no allocation, no Objective-C.

import Accelerate
import Foundation
import Synchronization

/// One reverb out, in rendered frames.
nonisolated struct MusicReverbSettings: Equatable, Sendable {
    /// From the request until the song is cut and the tail is heard.
    var cutAfterFrames: Int
    /// How long the tail is heard.
    var tailFrames: Int

    static let defaultWetGain: Float = 0.5
    /// The tail's lows below this stay out of the new song's way.
    static let highpassHz = 200.0
    /// The highs die first.
    static let dampingHz = 5_500.0
    /// A tail shorter than this decays as one of this length, so it never sounds gated from the start.
    static let shortestDecaySeconds = 1.2
}

nonisolated final class MusicReverbTail: @unchecked Sendable {
    let control = MusicEffectSwitch()

    private static let combMilliseconds = [37.1, 43.7, 51.1, 57.3, 64.9, 71.3, 79.7, 86.3]
    private static let allpassMilliseconds = [5.1, 12.7]
    private static let combCount = 8
    private static let allpassCount = 2
    private static let allpassGain: Float = 0.6
    /// The right channel's lines are a touch longer, so the tail is wide.
    private static let spreadSeconds = 23.0 / 44_100
    /// The wet comes in over this long, across the dry's own fade.
    private static let fadeInSeconds = 0.004

    private let sampleRate: Double
    // Request.
    private let cutRequest = Atomic<Int>(0)
    private let tailRequest = Atomic<Int>(0)

    // Renderer only. Comb `i` of channel `c` is line `c * combCount + i`.
    private let storage: UnsafeMutablePointer<Float>
    private let storageCount: Int
    private let combStart: UnsafeMutablePointer<Int>
    private let combLength: UnsafeMutablePointer<Int>
    private let combAt: UnsafeMutablePointer<Int>
    private let combGain: UnsafeMutablePointer<Float>
    private let combLow: UnsafeMutablePointer<Float>
    private let passStart: UnsafeMutablePointer<Int>
    private let passLength: UnsafeMutablePointer<Int>
    private let passAt: UnsafeMutablePointer<Int>
    private let damping: Float
    private let lowCoefficient: Float
    private let fadeInFrames: Int
    private var lowL: Float = 0
    private var lowR: Float = 0
    /// The second pole: one alone leaves too much of a bassline in the tail.
    private var deepL: Float = 0
    private var deepR: Float = 0
    private var normal: Float = 0
    private var untilCut = 0
    private var tail = 1
    private var heard = 0
    private var primed = false
    private var releaseLeft = 0
    private var releaseTotal = 1
    private var releasing = false

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        self.sampleRate = rate
        let combs = Self.combCount * 2, passes = Self.allpassCount * 2
        combStart = .allocate(capacity: combs)
        combLength = .allocate(capacity: combs)
        combAt = .allocate(capacity: combs)
        combGain = .allocate(capacity: combs)
        combLow = .allocate(capacity: combs)
        passStart = .allocate(capacity: passes)
        passLength = .allocate(capacity: passes)
        passAt = .allocate(capacity: passes)
        combAt.initialize(repeating: 0, count: combs)
        combGain.initialize(repeating: 0, count: combs)
        combLow.initialize(repeating: 0, count: combs)
        passAt.initialize(repeating: 0, count: passes)
        var total = 0
        for channel in 0..<2 {
            let spread = Double(channel) * Self.spreadSeconds
            for index in 0..<Self.combCount {
                let line = channel * Self.combCount + index
                let length = max(2, Int(((Self.combMilliseconds[index] / 1_000 + spread) * rate).rounded()))
                (combStart + line).initialize(to: total)
                (combLength + line).initialize(to: length)
                total += length
            }
            for index in 0..<Self.allpassCount {
                let line = channel * Self.allpassCount + index
                let length = max(2, Int(((Self.allpassMilliseconds[index] / 1_000 + spread) * rate).rounded()))
                (passStart + line).initialize(to: total)
                (passLength + line).initialize(to: length)
                total += length
            }
        }
        storageCount = total
        storage = .allocate(capacity: total)
        storage.initialize(repeating: 0, count: total)
        damping = Float(1 - exp(-2 * Double.pi * min(MusicReverbSettings.dampingHz, rate * 0.4) / rate))
        lowCoefficient = Float(1 - exp(-2 * Double.pi * MusicReverbSettings.highpassHz / rate))
        fadeInFrames = max(1, Int((Self.fadeInSeconds * rate).rounded()))
    }

    deinit {
        storage.deallocate()
        combStart.deallocate()
        combLength.deallocate()
        combAt.deallocate()
        combGain.deallocate()
        combLow.deallocate()
        passStart.deallocate()
        passLength.deallocate()
        passAt.deallocate()
    }

    // MARK: Any thread

    func begin(_ settings: MusicReverbSettings) {
        cutRequest.store(max(0, settings.cutAfterFrames), ordering: .relaxed)
        tailRequest.store(max(1, settings.tailFrames), ordering: .relaxed)
        control.begin()
    }

    #if DEBUG
    var debugSettings: MusicReverbSettings {
        MusicReverbSettings(
            cutAfterFrames: cutRequest.load(ordering: .relaxed), tailFrames: tailRequest.load(ordering: .relaxed)
        )
    }
    #endif

    // MARK: Render thread

    /// Picks up a request. True while the block has to go through `mix`.
    func prepare() -> Bool {
        let poll = control.poll()
        guard poll.isActive else { return false }
        if poll.starts {
            untilCut = cutRequest.load(ordering: .relaxed)
            tail = max(1, tailRequest.load(ordering: .relaxed))
            heard = 0
            primed = false
            releasing = false
        }
        if poll.releaseFrames > 0, !releasing {
            releasing = true
            releaseTotal = poll.releaseFrames
            releaseLeft = releaseTotal
        }
        return true
    }

    /// Blocks that are not rendered (the chain is muted): the song's end was not heard, so there is no tail of it either.
    func skip() {
        if control.poll().isActive { control.finish() }
    }

    /// Adds the tail to `samples`, which already carry the faded dry signal. `history` holds the song up to the end of this
    /// block. `scale` is the loudness offset the dry side was given.
    func mix(into samples: UnsafeMutablePointer<Float>, frames: Int, history: MusicEchoDelay, scale: Float = 1) {
        if releasing, !primed {
            control.finish()
            return
        }
        guard untilCut < frames else {
            untilCut -= frames
            return
        }
        let first = untilCut
        untilCut = 0
        if !primed {
            prime(from: history, newer: frames - first)
            primed = true
        }
        let gain = MusicReverbSettings.defaultWetGain * normal * scale
        let fadeFrom = tail - tail * 2 / 5
        for frame in first..<frames {
            guard heard < tail, !(releasing && releaseLeft == 0) else {
                control.finish()
                return
            }
            var ramp: Float = heard < fadeInFrames ? Float(heard + 1) / Float(fadeInFrames) : 1
            // The last stretch fades by itself, so a tail that was held short never stops dead.
            if heard >= fadeFrom { ramp *= Float(tail - heard) / Float(tail - fadeFrom) }
            if releasing {
                releaseLeft -= 1
                ramp *= Float(releaseLeft) / Float(releaseTotal)
            }
            heard += 1
            var left = next(channel: 0), right = next(channel: 1)
            lowL += lowCoefficient * (left - lowL)
            lowR += lowCoefficient * (right - lowR)
            left -= lowL
            right -= lowR
            deepL += lowCoefficient * (left - deepL)
            deepR += lowCoefficient * (right - deepR)
            left = Self.soft((left - deepL) * gain * ramp)
            right = Self.soft((right - deepR) * gain * ramp)
            samples[frame * 2] = min(1, max(-1, samples[frame * 2] + left))
            samples[frame * 2 + 1] = min(1, max(-1, samples[frame * 2 + 1] + right))
        }
        if heard >= tail || (releasing && releaseLeft == 0) { control.finish() }
    }

    /// One frame of one channel out of the combs and allpasses.
    @inline(__always)
    private func next(channel: Int) -> Float {
        var sum: Float = 0
        for line in (channel * Self.combCount)..<((channel + 1) * Self.combCount) {
            let at = combStart[line] + combAt[line]
            let out = storage[at]
            var low = combLow[line] + damping * (out - combLow[line])
            if !(abs(low) > 1e-18) || !low.isFinite { low = 0 }
            combLow[line] = low
            storage[at] = combGain[line] * low
            combAt[line] = combAt[line] + 1 == combLength[line] ? 0 : combAt[line] + 1
            // Every other comb is turned over, so a note they all ring on does not add up.
            sum += line & 1 == 0 ? out : -out
        }
        for line in (channel * Self.allpassCount)..<((channel + 1) * Self.allpassCount) {
            let at = passStart[line] + passAt[line]
            let held = storage[at]
            var kept = sum + Self.allpassGain * held
            if !(abs(kept) > 1e-18) || !kept.isFinite { kept = 0 }
            storage[at] = kept
            passAt[line] = passAt[line] + 1 == passLength[line] ? 0 : passAt[line] + 1
            sum = held - Self.allpassGain * kept
        }
        return sum
    }

    /// Fills the combs with the song's last second as if they had been fed all along. `newer` frames of the history are
    /// from after the cut and stay out.
    private func prime(from history: MusicEchoDelay, newer: Int) {
        memset(storage, 0, storageCount * MemoryLayout<Float>.size)
        lowL = 0
        lowR = 0
        deepL = 0
        deepR = 0
        let decay = max(MusicReverbSettings.shortestDecaySeconds, Double(tail) / sampleRate)
        var power = 0.0
        for line in 0..<(Self.combCount * 2) {
            let length = combLength[line]
            let gain = pow(10, -3 * Double(length) / sampleRate / decay)
            combGain[line] = Float(gain)
            combAt[line] = 0
            combLow[line] = 0
            power += 1 / (1 - gain * gain)
            var scale = 1.0
            var back = length + newer
            while back <= history.capacity, scale > 0.001 {
                history.addHistory(
                    channel: line / Self.combCount, framesBack: back, count: length, gain: Float(scale),
                    into: storage + combStart[line]
                )
                scale *= gain
                back += length
            }
        }
        // All combs together are as loud as the song was.
        normal = Float(1 / (power / 2).squareRoot())
        for line in 0..<(Self.allpassCount * 2) { passAt[line] = 0 }
    }

    /// Leaves everything up to 0.6 alone and bends what is above it, never past 1.
    @inline(__always)
    static func soft(_ value: Float) -> Float {
        let size = abs(value)
        guard size.isFinite else { return 0 }
        guard size > 0.6 else { return value }
        let over = size - 0.6
        let bent = 0.6 + over / (1 + over / 0.4)
        return value < 0 ? -bent : bent
    }
}
