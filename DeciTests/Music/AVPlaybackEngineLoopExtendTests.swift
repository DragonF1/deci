// DeciTests/Music/AVPlaybackEngineLoopExtendTests.swift
// Tier 4b P2b on the real engine with tone decks (chain at 0 gain, nothing is heard): the standby is a composition of the
// local file, everything above the engine sees song time, and a remote stream never gets one.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine loop extend")
struct AVPlaybackEngineLoopExtendTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/loop-engine", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
        let rate = 44_100.0
        let frames = Int(seconds * rate)
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = Float(0.2 * sin(2 * Double.pi * 440 * Double(frame) / rate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        try await ToneFile.write(interleavedStereo: samples, sampleRate: rate, to: url)
        return url
    }

    private func stream(_ name: String, duration: Double, url: URL, origin: ResolvedStream.Origin) -> ResolvedStream {
        ResolvedStream(
            videoId: name, url: url, itag: 140, durationSeconds: duration, expiresAt: .distantFuture,
            playbackTrackingURL: nil, httpHeaders: [:], origin: origin
        )
    }

    /// A loop plan: B starts at 1 s, loops 1...2 s twice (a 2 s extension), the outgoing song mixes out at 4 s.
    private func loopPlan(mixOut: Double = 4) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 1, outgoingEndSec: mixOut + 2, fadeStartSec: mixOut, fadeSeconds: 2,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
        plan.style = .loopExtend
        plan.incomingRate = 1
        plan.mixOutSec = mixOut
        plan.mixInSec = 1
        plan.overlapBars = 1
        plan.overlapSec = 2
        plan.barSec = 2
        plan.glideBackSec = 0
        plan.fallbackIncomingStartSec = 0
        plan.loopStartSec = 1
        plan.loopBars = 1
        plan.loopLengthSec = 1
        plan.loopRepeats = 2
        return plan
    }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    private func flipped(origin: ResolvedStream.Origin = .trackCache) async throws -> AVPlaybackEngine {
        let a = try await writeTone("la", seconds: 8)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("la", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: true)
        engine.preload(stream("lb", duration: 20, url: b, origin: origin), plan: loopPlan())
        let didFlip = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
        #expect(didFlip)
        return engine
    }

    @Test("a local standby for a loop plan is a composition with the loop map; the plan keeps its loop")
    func localStandbyIsComposed() async throws {
        let a = try await writeTone("la", seconds: 8)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("la", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: false)
        engine.preload(stream("lb", duration: 20, url: b, origin: .download), plan: loopPlan())
        // The composition is built off the main actor, so the map appears a moment after the preload.
        let built = await waitUntil(timeout: .seconds(20)) { engine.debugStandbyLoop != nil }
        #expect(built)
        let map = try #require(engine.debugStandbyLoop)
        #expect(map.loopEnd == 2 && map.extensionSec == 2)
        #expect(engine.transitionPlan?.style == .loopExtend && engine.transitionPlan?.loopRepeats == 2)
        #expect(engine.debugStandbyStartOffset == 1, "parked on the mix-in, which is before the loop's end: the same in both times")
        engine.cancelPreload()
        #expect(engine.debugStandbyLoop == nil)
        engine.unload()
    }

    @Test("a remote standby is never composed: no map, and the plan runs as the plain blend")
    func remoteStandbyIsNotComposed() async throws {
        let a = try await writeTone("la", seconds: 8)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("la", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: false)
        var asked = loopPlan()
        asked.fallbackIncomingStartSec = 0.5
        engine.preload(stream("lb", duration: 20, url: b, origin: .network), plan: asked)
        #expect(engine.debugStandbyLoop == nil)
        let plan = try #require(engine.transitionPlan)
        // The unguarded blend's overlap is over the vocal budget by construction: the beat plan is given up and the standby
        // is parked on the smart plan's start, so the guarded fade runs.
        #expect(engine.debugBeatGivenUp)
        #expect(plan.incomingStartSec == 0.5 && engine.debugStandbyStartOffset == 0.5)
        #expect(plan.style == .longBlend && plan.loopRepeats == 0 && plan.loopLengthSec == 0 && plan.loopStartSec == 0 && plan.loopBars == 0)
        #expect(plan.mixInSec == 1 && plan.mode == .beat, "the blend itself is untouched")
        engine.unload()
    }

    @Test("a loop standby refuses a manual-skip crossfade and a plan with another loop")
    func skipAndReplanRefused() async throws {
        let a = try await writeTone("la", seconds: 30)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("la", duration: 30, url: a, origin: .trackCache), startAt: 0, autoplay: true)
        engine.preload(stream("lb", duration: 20, url: b, origin: .trackCache), plan: loopPlan(mixOut: 25))
        let ready = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(ready)
        #expect(engine.debugStandbyLoop != nil)
        #expect(!engine.canCrossfadeToPreloaded, "the skip takes the ordinary load")
        var other = loopPlan(mixOut: 25)
        other.loopRepeats = 1
        engine.updateTransitionPlan(other)
        #expect(engine.transitionPlan?.loopRepeats == 2, "a different loop is not adopted")
        var plain = loopPlan(mixOut: 25)
        plain.style = .longBlend
        engine.updateTransitionPlan(plain)
        #expect(engine.transitionPlan?.style == .loopExtend)
        engine.unload()
    }

    @Test("after the flip the position is song time: held at the loop's end in the repeats, shifted back after them")
    func positionIsSongTime() async throws {
        let engine = try await flipped()
        let map = try #require(engine.debugActiveLoop)
        #expect(engine.lastTransitionStyle == .loopExtend)
        var sawRepeats = false, sawAfter = false
        let began = Date()
        while Date().timeIntervalSince(began) < 9 {
            let before = engine.avPlayer.currentTime().seconds
            let position = engine.position
            let after = engine.avPlayer.currentTime().seconds
            guard before.isFinite, after.isFinite else { continue }
            #expect(position >= map.songTime(before) - 1e-6 && position <= map.songTime(after) + 1e-6,
                    "item \(before)...\(after) reported \(position)")
            if before > 2.2, after < 3.8 { sawRepeats = true; #expect(position == 2, "held at the loop's end") }
            if before > 4.3 { sawAfter = true; #expect(abs(position - (before - 2)) < 0.3) }
            if sawAfter { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawRepeats && sawAfter)
        engine.unload()
    }

    @Test("a seek is in song time: before the loop's end it is the first pass, after it the extension is added")
    func seekMaps() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        engine.seek(to: 8)
        let landed = await waitUntil(timeout: .seconds(10)) { abs(engine.avPlayer.currentTime().seconds - 10) < 0.5 }
        #expect(landed, "song 8 s is composition 10 s")
        #expect(abs(engine.position - 8) < 0.5)
        engine.seek(to: 1.5)
        let first = await waitUntil(timeout: .seconds(10)) { abs(engine.avPlayer.currentTime().seconds - 1.5) < 0.5 }
        #expect(first, "before the loop's end the two times are the same")
        engine.unload()
    }

    @Test("the active loop deck's end is the song's end plus the extension, and the plan's mix-out is mapped the same way")
    func endIsMapped() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(10)) { !engine.isCrossfading }
        #expect(over)
        let end = try #require(engine.avPlayer.currentItem?.forwardPlaybackEndTime)
        #expect(abs(end.seconds - 22) < 0.01, "20 s song and a 2 s extension: \(end.seconds)")
        engine.unload()
    }

    @Test("an ordinary preload is untouched: no map, the end is the song's own")
    func ordinaryPreload() async throws {
        let a = try await writeTone("la", seconds: 8)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("la", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: false)
        var plan = loopPlan()
        plan.style = .longBlend
        engine.preload(stream("lb", duration: 20, url: b, origin: .trackCache), plan: plan)
        #expect(engine.debugStandbyLoop == nil && engine.debugActiveLoop == nil)
        engine.unload()
    }

    @Test("a seek into the trimmed end gives the beat plan up: the standby is rebuilt as the plain item on the smart start")
    func fallbackRebuildsPlain() async throws {
        let a = try await writeTone("la", seconds: 30)
        let b = try await writeTone("lb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("la", duration: 30, url: a, origin: .trackCache), startAt: 0, autoplay: true)
        var plan = loopPlan(mixOut: 25)
        plan.fallbackIncomingStartSec = 0.5
        engine.preload(stream("lb", duration: 20, url: b, origin: .trackCache), plan: plan)
        let ready = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(ready && engine.debugStandbyLoop != nil)
        engine.seek(to: 26)
        #expect(engine.debugStandbyLoop == nil, "the repeats would play with nothing over them")
        #expect(engine.debugBeatGivenUp)
        let again = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(again, "the plain standby prerolls on its own")
        #expect(engine.transitionPlan?.style == .longBlend && engine.transitionPlan?.loopRepeats == 0)
        #expect(engine.debugStandbyStartOffset == 0.5 && engine.transitionPlan?.incomingStartSec == 0.5)
        #expect(engine.debugStandbyLoop == nil)
        engine.unload()
    }

    @Test("pausing and resuming the beat blend after a looped song reads the outgoing deck in song time: no extension-sized seek")
    func resumeAfterLoopedOutgoing() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(over)
        #expect(engine.debugActiveLoop != nil)
        // The looped song B is now the outgoing deck of a beat blend into C: mix-out at song 5 s (item 7 s), 3 s overlap.
        let c = try await writeTone("lc", seconds: 20)
        var next = loopPlan(mixOut: 5)
        next.style = .longBlend
        next.loopStartSec = 0; next.loopBars = 0; next.loopLengthSec = 0; next.loopRepeats = 0
        next.fadeSeconds = 3
        next.overlapSec = 3
        next.outgoingEndSec = 8
        engine.preload(stream("lc", duration: 20, url: c, origin: .trackCache), plan: next)
        let crossing = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
        #expect(crossing)
        guard engine.debugBeatOverlap != nil else { Issue.record("not a beat overlap"); engine.unload(); return }
        engine.pause()
        let before = engine.avPlayer.currentTime().seconds
        engine.play()
        try await Task.sleep(for: .milliseconds(600))
        let after = engine.avPlayer.currentTime().seconds
        #expect(after > before - 0.3 && after < before + 1.5, "the incoming deck went from \(before) to \(after) s")
        engine.unload()
    }
}
