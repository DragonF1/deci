// Deci/Music/Playback/MusicLoopRoll.swift
// The loop roll: one bar that builds. Its first beat plays as it is and is recorded, the second repeats it, the third plays
// its first half twice and the fourth its first quarter four times; then the song goes on where it is by then. It works on
// the outgoing deck's signal in place, before the fade. Every seam is bridged: what the jump would click with is added to
// the new sound and fades out within a few milliseconds. Allocated once with the lease. Render safe: no lock, no allocation,
// no Objective-C.

import Foundation
import Synchronization

/// One roll, in rendered frames.
nonisolated struct MusicRollSettings: Equatable, Sendable {
    /// From the request to the bar's first beat.
    var startFrame: Int
    var beatFrames: Int

    /// The longest beat that is rolled, in seconds.
    static let maxBeatSeconds = 1.0
    static let beats = 4
}

nonisolated final class MusicLoopRoll: @unchecked Sendable {
    let control = MusicEffectSwitch()

    private static let bridgeSeconds = 0.002_5

    // Request.
    private let startRequest = Atomic<Int>(0)
    private let beatRequest = Atomic<Int>(1)

    // Renderer only.
    private let capacity: Int
    private let recording: UnsafeMutablePointer<Float>
    private let bridgeFrames: Int
    private var start = 0
    private var beat = 1
    /// Frames since the request.
    private var position = 0
    private var lastL: Float = 0
    private var lastR: Float = 0
    private var bridgeL: Float = 0
    private var bridgeR: Float = 0
    private var bridgeLeft = 0
    private var leaving = false

    init(sampleRate: Double) {
        let rate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
        capacity = max(4, Int((MusicRollSettings.maxBeatSeconds * rate).rounded(.up)))
        recording = .allocate(capacity: capacity * 2)
        recording.initialize(repeating: 0, count: capacity * 2)
        bridgeFrames = max(1, Int((Self.bridgeSeconds * rate).rounded()))
    }

    deinit { recording.deallocate() }

    // MARK: Any thread

    func begin(_ settings: MusicRollSettings) {
        guard settings.startFrame >= 0, settings.beatFrames >= 4, settings.beatFrames <= capacity else { return }
        startRequest.store(settings.startFrame, ordering: .relaxed)
        beatRequest.store(settings.beatFrames, ordering: .relaxed)
        control.begin()
    }

    #if DEBUG
    var debugSettings: MusicRollSettings {
        MusicRollSettings(
            startFrame: startRequest.load(ordering: .relaxed), beatFrames: beatRequest.load(ordering: .relaxed)
        )
    }
    #endif

    // MARK: Render thread

    /// Blocks that are not rendered (the chain is muted): the roll is over.
    func skip() {
        if control.poll().isActive { control.finish() }
    }

    func process(_ samples: UnsafeMutablePointer<Float>, frames: Int) {
        let poll = control.poll()
        guard poll.isActive else { return }
        if poll.starts {
            start = startRequest.load(ordering: .relaxed)
            beat = min(capacity, max(4, beatRequest.load(ordering: .relaxed)))
            position = 0
            bridgeLeft = 0
            leaving = false
        }
        // A release goes back to the song at once (bridged), or drops a roll that has not begun.
        if poll.releaseFrames > 0 { leaving = true }
        let bar = MusicRollSettings.beats * beat
        if leaving, position <= start + beat {
            control.finish()
            return
        }
        guard position + frames > start else {
            position += frames
            return
        }
        for frame in 0..<frames {
            let at = position - start
            position += 1
            guard at >= 0 else { continue }
            let liveL = samples[frame * 2], liveR = samples[frame * 2 + 1]
            var outL = liveL, outR = liveR
            var seam = false
            if at < beat {
                recording[at * 2] = liveL
                recording[at * 2 + 1] = liveR
            } else if at < bar, !leaving {
                let source = Self.source(of: at, beat: beat)
                outL = recording[source * 2]
                outR = recording[source * 2 + 1]
                seam = source == 0
            } else if at == bar || leaving {
                // Back to the song: at the end of the bar, or where a release found the roll.
                seam = true
                leaving = false
                start = position - 1 - bar
            }
            if seam {
                bridgeL = lastL - outL
                bridgeR = lastR - outR
                if !bridgeL.isFinite { bridgeL = 0 }
                if !bridgeR.isFinite { bridgeR = 0 }
                bridgeLeft = bridgeFrames
            }
            if bridgeLeft > 0 {
                let share = Float(bridgeLeft) / Float(bridgeFrames)
                outL += bridgeL * share
                outR += bridgeR * share
                bridgeLeft -= 1
                samples[frame * 2] = outL
                samples[frame * 2 + 1] = outR
            } else if at >= beat, at < bar {
                samples[frame * 2] = outL
                samples[frame * 2 + 1] = outR
            }
            lastL = outL
            lastR = outR
        }
        if position > start + bar, bridgeLeft == 0 { control.finish() }
    }

    /// The recorded frame the roll plays `at` frames into its bar (at or past the first beat).
    static func source(of at: Int, beat: Int) -> Int {
        let inBeat = at % beat
        switch at / beat {
        case 2: return inBeat % max(1, beat / 2)
        case 3: return inBeat % max(1, beat / 4)
        default: return inBeat
        }
    }
}
