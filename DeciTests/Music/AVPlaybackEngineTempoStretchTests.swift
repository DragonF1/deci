// DeciTests/Music/AVPlaybackEngineTempoStretchTests.swift
// Tempo match on the real engine with tone decks (chain at 0 gain, nothing is heard): the standby is a composition of the
// local file with its tempo matched for the overlap, everything above the engine sees song time, the player's rate is never
// written, and a song taken back to its matched part plays plain (wjyijr: it must never stay slowed down).

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine tempo stretch")
struct AVPlaybackEngineTempoStretchTests {
    static let rate = 1045.0 / 1024

    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/tempo-engine", isDirectory: true)
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

    /// B starts at 1 s at 1045/1024 for 2 s, then glides over two 1 s bars: at its own tempo from 5.13 s of the song.
    private func stretchPlan(mixOut: Double = 4) -> TransitionPlan {
        var plan = TransitionPlan(
            mode: .beat, incomingStartSec: 1, outgoingEndSec: mixOut + 2, fadeStartSec: mixOut, fadeSeconds: 2,
            incomingGainDb: 0, incomingGlideSeconds: 0, outgoingGainDb: 0, outgoingRampSeconds: 0, reason: .ok
        )
        plan.style = .longBlend
        plan.incomingRate = 1
        plan.mixOutSec = mixOut
        plan.mixInSec = 1
        plan.overlapBars = 1
        plan.overlapSec = 2
        plan.barSec = 2
        plan.fallbackIncomingStartSec = 0.5
        plan.stretchRate = Self.rate
        plan.stretchGlideBars = 2
        plan.stretchBarSec = 1
        return plan
    }

    private var stretchEnd: Double { 1 + 2 * Self.rate + 0.375 / 4 + 2 }

    private func makeEngine() -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        return AVPlaybackEngine(chain: chain)
    }

    private func loaded(
        aSeconds: Double = 8, mixOut: Double = 4, origin: ResolvedStream.Origin = .trackCache, autoplay: Bool = true
    ) async throws -> AVPlaybackEngine {
        let a = try await writeTone("ta", seconds: aSeconds)
        let b = try await writeTone("tb", seconds: 20)
        let engine = makeEngine()
        engine.crossfadeSeconds = 2
        engine.load(stream("ta", duration: aSeconds, url: a, origin: .trackCache), startAt: 0, autoplay: autoplay)
        engine.preload(stream("tb", duration: 20, url: b, origin: origin), plan: stretchPlan(mixOut: mixOut))
        return engine
    }

    private func flipped() async throws -> AVPlaybackEngine {
        let engine = try await loaded()
        let didFlip = await waitUntil(timeout: .seconds(40)) { engine.isCrossfading }
        #expect(didFlip)
        return engine
    }

    @Test("a local standby for a matched plan is a composition with its map, parked on the mix-in")
    func localStandbyIsComposed() async throws {
        let engine = try await loaded(autoplay: false)
        let built = await waitUntil(timeout: .seconds(20)) { engine.debugStandbyStretch != nil }
        #expect(built)
        let map = try #require(engine.debugStandbyStretch)
        #expect(abs(map.stretchEnd - stretchEnd) < 1e-3)
        #expect(engine.debugStandbyLoop == nil && engine.debugStandbyStartOffset == 1)
        #expect(engine.transitionPlan?.stretchRate == Self.rate)
        #expect(engine.ownTempoFrom == 0, "the playing song is the plain one")
        engine.cancelPreload()
        #expect(engine.debugStandbyStretch == nil)
        engine.unload()
    }

    @Test("a remote standby is never composed: the beat plan is given up for the smart start")
    func remoteStandbyIsNotComposed() async throws {
        let engine = try await loaded(origin: .network, autoplay: false)
        #expect(engine.debugStandbyStretch == nil && engine.debugBeatGivenUp)
        let plan = try #require(engine.transitionPlan)
        #expect(plan.stretchRate == 1 && plan.stretchGlideBars == 0 && plan.stretchBarSec == 0)
        #expect(plan.incomingStartSec == 0.5 && engine.debugStandbyStartOffset == 0.5)
        engine.unload()
    }

    @Test("a song too short for its glide is the plain song, and the beat plan is given up")
    func tooShortIsPlain() async throws {
        let a = try await writeTone("ta", seconds: 8)
        let b = try await writeTone("tb", seconds: 5)
        let engine = makeEngine()
        engine.load(stream("ta", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: false)
        engine.preload(stream("tb", duration: 5, url: b, origin: .trackCache), plan: stretchPlan())
        let gaveUp = await waitUntil(timeout: .seconds(20)) { engine.debugBeatGivenUp }
        #expect(gaveUp)
        #expect(engine.debugStandbyStretch == nil && engine.transitionPlan?.stretchRate == 1)
        engine.unload()
    }

    @Test("a matched standby refuses a manual-skip crossfade and a plan with another tempo")
    func skipAndReplanRefused() async throws {
        let engine = try await loaded(aSeconds: 30, mixOut: 25)
        let ready = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(ready && engine.debugStandbyStretch != nil)
        #expect(!engine.canCrossfadeToPreloaded, "the skip takes the ordinary load")
        var other = stretchPlan(mixOut: 25)
        other.stretchRate = 1040.0 / 1024
        engine.updateTransitionPlan(other)
        #expect(engine.transitionPlan?.stretchRate == Self.rate)
        var plain = stretchPlan(mixOut: 25)
        plain.clearItemEdit()
        engine.updateTransitionPlan(plain)
        #expect(engine.transitionPlan?.stretchRate == Self.rate)
        engine.unload()
    }

    @Test("through the overlap, the glide and the rest the position is song time and the player's rate is never written")
    func positionIsSongTime() async throws {
        let engine = try await flipped()
        let map = try #require(engine.debugActiveStretch)
        #expect(engine.lastTransitionStyle == .longBlend)
        #expect(abs(engine.ownTempoFrom - stretchEnd) < 1e-3)
        var sawOverlap = false, sawRest = false
        let began = Date()
        while Date().timeIntervalSince(began) < 9, !sawRest {
            let before = engine.avPlayer.currentTime().seconds
            let position = engine.position
            let after = engine.avPlayer.currentTime().seconds
            if before.isFinite, after.isFinite {
                #expect(position >= map.songTime(before) - 1e-6 && position <= map.songTime(after) + 1e-6,
                        "item \(before)...\(after) reported \(position)")
                if before > 1.5, after < 2.8 { sawOverlap = true; #expect(position > before, "faster than its own tempo") }
                if position > stretchEnd + 0.5 { sawRest = true }
            }
            #expect(engine.avPlayer.rate == 0 || engine.avPlayer.rate == 1)
            #expect(engine.deckRate == 1)
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(sawOverlap && sawRest)
        #expect(engine.playingRateWriteCount == 0)
        engine.unload()
    }

    @Test("after the glide song time runs second for second: the song is at its own tempo")
    func ownTempoAfterTheGlide() async throws {
        let engine = try await flipped()
        let past = await waitUntil(timeout: .seconds(20)) { engine.position > self.stretchEnd + 0.2 }
        #expect(past)
        let songA = engine.position, itemA = engine.avPlayer.currentTime().seconds
        try await Task.sleep(for: .seconds(2))
        let songB = engine.position, itemB = engine.avPlayer.currentTime().seconds
        #expect(abs((songB - songA) - (itemB - itemA)) < 0.02, "song \(songB - songA) s in item \(itemB - itemA) s")
        let segments = (engine.avPlayer.currentItem?.asset as? AVComposition)?.tracks.first?.segments ?? []
        let last = try #require(segments.last)
        #expect(last.timeMapping.source.duration == last.timeMapping.target.duration, "the last piece is not scaled")
        engine.unload()
    }

    @Test("the active deck's end is the song's end in item time")
    func endIsMapped() async throws {
        let engine = try await flipped()
        let map = try #require(engine.debugActiveStretch)
        let end = try #require(engine.avPlayer.currentItem?.forwardPlaybackEndTime)
        #expect(abs(end.seconds - map.itemTime(20)) < 0.01 && end.seconds < 20)
        engine.unload()
    }

    @Test("a seek past the glide is in song time and keeps the item")
    func seekForward() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(over)
        let map = try #require(engine.debugActiveStretch)
        engine.seek(to: 12)
        let landed = await waitUntil(timeout: .seconds(10)) { abs(engine.avPlayer.currentTime().seconds - map.itemTime(12)) < 0.5 }
        #expect(landed && abs(engine.position - 12) < 0.6)
        #expect(engine.debugActiveStretch != nil)
        engine.unload()
    }

    @Test("a seek back into the matched part plays the song plain from there, and the position never jumps to 0")
    func seekBackPlaysPlain() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(over)
        var advanced = false, ended = false, failed = false
        engine.onEvent = { event in
            if case .advanced = event { advanced = true }
            if case .ended = event { ended = true }
            if case .failed = event { failed = true }
        }
        var ticked: [TimeInterval] = []
        engine.onTick = { position, _ in ticked.append(position) }
        engine.seek(to: 2)
        #expect(engine.position == 2 && engine.debugActiveStretch == nil && engine.ownTempoFrom == 0)
        var lowest = Double.infinity
        let playing = await waitUntil(timeout: .seconds(20)) {
            lowest = min(lowest, engine.position)
            return engine.position > 3 && engine.avPlayer.timeControlStatus == .playing
        }
        #expect(playing, "at \(engine.position)")
        #expect(lowest >= 1.9 && ticked.allSatisfy { $0 >= 1.9 }, "lowest \(lowest), ticks \(ticked)")
        #expect(!(engine.avPlayer.currentItem?.asset is AVComposition), "the plain song")
        #expect(abs(engine.position - engine.avPlayer.currentTime().seconds) < 0.1)
        #expect(!advanced && !ended && !failed)
        #expect(engine.avPlayer.rate == 1 && engine.playingRateWriteCount == 0)
        engine.unload()
    }

    @Test("a second seek while the plain song is being built wins, and a pause holds it there")
    func seekTwiceAndPause() async throws {
        let engine = try await flipped()
        let over = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(over)
        engine.pause()
        engine.seek(to: 2)
        engine.seek(to: 3.5)
        #expect(engine.position == 3.5)
        let landed = await waitUntil(timeout: .seconds(20)) { abs(engine.avPlayer.currentTime().seconds - 3.5) < 0.1 }
        #expect(landed && abs(engine.position - 3.5) < 0.1)
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.avPlayer.rate == 0)
        engine.play()
        let moving = await waitUntil(timeout: .seconds(10)) { engine.position > 4 }
        #expect(moving)
        engine.unload()
    }

    @Test("a seek into the trimmed end gives the beat plan up: the standby is the plain song on the smart start")
    func fallbackRebuildsPlain() async throws {
        let engine = try await loaded(aSeconds: 30, mixOut: 25)
        let ready = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(ready && engine.debugStandbyStretch != nil)
        engine.seek(to: 26)
        #expect(engine.debugStandbyStretch == nil && engine.debugBeatGivenUp)
        let again = await waitUntil(timeout: .seconds(40)) { engine.preloadIsReady }
        #expect(again)
        #expect(engine.transitionPlan?.stretchRate == 1 && engine.debugStandbyStartOffset == 0.5)
        engine.unload()
    }

    @Test("an ordinary preload is untouched: no map, a plain asset")
    func ordinaryPreload() async throws {
        let a = try await writeTone("ta", seconds: 8)
        let b = try await writeTone("tb", seconds: 20)
        let engine = makeEngine()
        engine.load(stream("ta", duration: 8, url: a, origin: .trackCache), startAt: 0, autoplay: false)
        var plan = stretchPlan()
        plan.clearItemEdit()
        engine.preload(stream("tb", duration: 20, url: b, origin: .trackCache), plan: plan)
        #expect(engine.debugStandbyStretch == nil && engine.debugActiveStretch == nil && engine.ownTempoFrom == 0)
        #expect(!engine.debugBeatGivenUp)
        engine.unload()
    }
}
