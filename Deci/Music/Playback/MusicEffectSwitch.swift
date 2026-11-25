// Deci/Music/Playback/MusicEffectSwitch.swift
// The on, release and off switch one mixing effect of a lease shares between the thread that asks for it and the render
// thread. The effect stores its settings (relaxed) and then calls `begin`. A run is over for good once the renderer has
// called `finish` for it, and a request that arrives at that very moment is a new run, never lost. Render safe: no lock.

import Foundation
import Synchronization

nonisolated final class MusicEffectSwitch: @unchecked Sendable {
    /// What the renderer does with the effect this block.
    struct Poll: Equatable, Sendable {
        var isActive = false
        /// The settings are new: start over.
        var starts = false
        /// Fade out over this many frames from now (0 = no release was asked for).
        var releaseFrames = 0
    }

    private let activeFlag = Atomic<Bool>(false)
    private let generation = Atomic<Int>(0)
    /// The run the renderer is done with.
    private let finishedGeneration = Atomic<Int>(0)
    private let releaseGeneration = Atomic<Int>(0)
    private let releaseLength = Atomic<Int>(1)
    /// `releaseGeneration` as the last `begin` found it: a release from before a run never ends it.
    private let releaseBase = Atomic<Int>(0)

    // Renderer only.
    private nonisolated(unsafe) var seenGeneration = 0
    private nonisolated(unsafe) var seenRelease = 0

    // MARK: Any thread

    /// Starts a run with the settings stored before this call. A later call replaces the run in progress.
    func begin() {
        releaseBase.store(releaseGeneration.load(ordering: .relaxed), ordering: .relaxed)
        // Generation first, flag second: a renderer that sees the flag also sees the new generation and its settings.
        generation.wrappingAdd(1, ordering: .releasing)
        activeFlag.store(true, ordering: .releasing)
    }

    /// Ends the run early, over `frames` rendered frames.
    func release(frames: Int) {
        releaseLength.store(max(1, frames), ordering: .relaxed)
        releaseGeneration.wrappingAdd(1, ordering: .releasing)
    }

    /// The effect is off at the next render.
    func end() { activeFlag.store(false, ordering: .releasing) }

    /// Asked for and neither ended nor run out.
    var isActive: Bool {
        activeFlag.load(ordering: .acquiring)
            && finishedGeneration.load(ordering: .acquiring) != generation.load(ordering: .acquiring)
    }

    // MARK: Render thread

    func poll() -> Poll {
        guard isActive else { return Poll() }
        var poll = Poll(isActive: true)
        let asked = generation.load(ordering: .acquiring)
        if asked != seenGeneration {
            seenGeneration = asked
            seenRelease = releaseBase.load(ordering: .relaxed)
            poll.starts = true
        }
        let released = releaseGeneration.load(ordering: .acquiring)
        if released != seenRelease {
            seenRelease = released
            poll.releaseFrames = releaseLength.load(ordering: .relaxed)
        }
        return poll
    }

    /// The run the last `poll` returned has nothing left to do.
    func finish() { finishedGeneration.store(seenGeneration, ordering: .releasing) }

    #if DEBUG
    /// What was asked for, for the tests.
    var debugRuns: Int { generation.load(ordering: .relaxed) }
    var debugReleases: (count: Int, frames: Int) {
        (releaseGeneration.load(ordering: .relaxed), releaseLength.load(ordering: .relaxed))
    }
    #endif
}
