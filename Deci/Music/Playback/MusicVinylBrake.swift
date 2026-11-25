// Deci/Music/Playback/MusicVinylBrake.swift
// The brake: the platter stops. From the cut the outgoing song, which still arrives, is recorded, and read back at a speed
// that falls from 1 to 0 over about a beat. The deck's own rate is never touched: the pitch drop is made here, from the
// recording (read slower than it is written, so it can never run dry). Allocated once with the lease. Render safe: no lock,
// no allocation, no Objective-C.

import Foundation
import Synchronization

/// One brake, in rendered frames.
nonisolated struct MusicBrakeSettings: Equatable, Sendable {
    /// From the request until the song is cut and the platter starts to slow down.
    var cutAfterFrames: Int
    /// Until it stands still.
    var lengthFrames: Int
    /// How loud it starts.
    var gain: Float

    /// The longest brake, in seconds.
    static let maxSeconds = 0.6
    /// The shortest one that is still heard as a brake.
    static let minSeconds = 0.4
    /// Alone before the new song's "1", and over the new song.
    static let soloGain: Float = 0.9
    static let coveredGain: Float = 0.6
}

nonisolated final class MusicVinylBrake: @unchecked Sendable {
    let control = MusicEffectSwitch()

    private static let fadeInSeconds = 0.004

    // Request.
    private let cutRequest = Atomic<Int>(0)
    private let lengthRequest = Atomic<Int>(1)
    private let gainRequest = Atomic<UInt32>(MusicBrakeSettings.soloGain.bitPattern)

    // Renderer only.
    private let capacity: Int
    private let recording: UnsafeMutablePointer<Float>
    private let fadeInFrames: Int
    private var untilCut = 0
    private var length = 1
    private var gain: Float = 0
    private var recorded = 0
    private var played = 0
    private var releaseLeft = 0
    private var releaseTotal = 1
    private var releasing = false

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        // A speed that falls evenly to 0 reads half as much as it lasts.
        capacity = Int((MusicBrakeSettings.maxSeconds / 2 * rate).rounded(.up)) + 2
        recording = .allocate(capacity: capacity * 2)
        recording.initialize(repeating: 0, count: capacity * 2)
        fadeInFrames = max(1, Int((Self.fadeInSeconds * rate).rounded()))
    }

    deinit { recording.deallocate() }

    // MARK: Any thread

    func begin(_ settings: MusicBrakeSettings) {
        cutRequest.store(max(0, settings.cutAfterFrames), ordering: .relaxed)
        lengthRequest.store(max(1, settings.lengthFrames), ordering: .relaxed)
        let gain = settings.gain.isFinite ? min(1, max(0, settings.gain)) : MusicBrakeSettings.coveredGain
        gainRequest.store(gain.bitPattern, ordering: .relaxed)
        control.begin()
    }

    #if DEBUG
    var debugSettings: MusicBrakeSettings {
        MusicBrakeSettings(
            cutAfterFrames: cutRequest.load(ordering: .relaxed), lengthFrames: lengthRequest.load(ordering: .relaxed),
            gain: Float(bitPattern: gainRequest.load(ordering: .relaxed))
        )
    }
    #endif

    // MARK: Render thread

    /// Picks up a request and records the block (the signal before its fade). True while the block has to go through `mix`.
    func prepare(_ input: UnsafePointer<Float>, frames: Int) -> Bool {
        let poll = control.poll()
        guard poll.isActive else { return false }
        if poll.starts {
            untilCut = cutRequest.load(ordering: .relaxed)
            length = max(1, min(lengthRequest.load(ordering: .relaxed), (capacity - 2) * 2))
            gain = Float(bitPattern: gainRequest.load(ordering: .relaxed))
            recorded = 0
            played = 0
            releasing = false
        }
        if poll.releaseFrames > 0, !releasing {
            releasing = true
            releaseTotal = poll.releaseFrames
            releaseLeft = releaseTotal
        }
        if untilCut < frames {
            let count = min(frames - untilCut, capacity - recorded)
            if count > 0 {
                memcpy(recording + recorded * 2, input + untilCut * 2, count * 2 * MemoryLayout<Float>.size)
                recorded += count
            }
        }
        return true
    }

    /// Blocks that are not rendered (the chain is muted): the brake is over.
    func skip() {
        if control.poll().isActive { control.finish() }
    }

    /// Adds the slowing song to `samples`, which already carry the faded dry signal. `scale` is the loudness offset the dry
    /// side was given.
    func mix(into samples: UnsafeMutablePointer<Float>, frames: Int, scale: Float = 1) {
        if releasing, untilCut >= frames {
            control.finish()
            return
        }
        guard untilCut < frames else {
            untilCut -= frames
            return
        }
        let first = untilCut
        untilCut = 0
        let total = Double(length)
        for frame in first..<frames {
            guard played < length, recorded > 0, !(releasing && releaseLeft == 0) else {
                control.finish()
                return
            }
            let time = Double(played)
            let position = time - time * time / (2 * total)
            let index = min(Int(position), recorded - 1)
            let after = min(index + 1, recorded - 1)
            let part = Float(position - Double(Int(position)))
            let share = Float(time / total)
            var level = gain * scale * (1 - share * share * share)
            if played < fadeInFrames { level *= Float(played + 1) / Float(fadeInFrames) }
            if releasing {
                releaseLeft -= 1
                level *= Float(releaseLeft) / Float(releaseTotal)
            }
            played += 1
            var left = recording[index * 2] + (recording[after * 2] - recording[index * 2]) * part
            var right = recording[index * 2 + 1] + (recording[after * 2 + 1] - recording[index * 2 + 1]) * part
            if !left.isFinite { left = 0 }
            if !right.isFinite { right = 0 }
            samples[frame * 2] = min(1, max(-1, samples[frame * 2] + left * level))
            samples[frame * 2 + 1] = min(1, max(-1, samples[frame * 2 + 1] + right * level))
        }
        if played >= length || (releasing && releaseLeft == 0) { control.finish() }
    }
}
