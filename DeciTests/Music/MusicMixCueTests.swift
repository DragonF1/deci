// DeciTests/Music/MusicMixCueTests.swift
// The "Mixing" cue: when its label is due, how the player mirrors it, and when the real engine sends it (a scheduled
// crossfade, never a gapless switch or a manual skip, withdrawn by a pause).

import Foundation
import AVFoundation
import Testing
@testable import Deci

@Suite("MusicMixCue label timing")
struct MusicMixCueTimingTests {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000_000)

    @Test("an upcoming mix shows its label from 5 s before the overlap")
    func upcomingLead() {
        let cue = MusicMixCue.upcoming(startsAt: now.addingTimeInterval(6))
        #expect(!cue.showsLabel(at: now))
        #expect(abs(cue.secondsUntilLabel(from: now) - 1) < 1e-9)
        #expect(!cue.showsLabel(at: now.addingTimeInterval(0.99)))
        #expect(cue.showsLabel(at: now.addingTimeInterval(1)))
        #expect(cue.showsLabel(at: now.addingTimeInterval(7)), "a late start still shows")
    }

    @Test("a mix scheduled less than 5 s ahead, or one that is playing, shows at once")
    func atOnce() {
        #expect(MusicMixCue.upcoming(startsAt: now.addingTimeInterval(3)).secondsUntilLabel(from: now) == 0)
        #expect(MusicMixCue.mixing.showsLabel(at: now))
        #expect(MusicMixCue.mixing.secondsUntilLabel(from: now) == 0)
    }
}

@MainActor
@Suite("MusicPlayer mix cue")
struct MusicPlayerMixCueTests {
    @Test("the player mirrors the engine's cue and does not report it as a state change")
    func mirrors() {
        let engine = FakePlaybackEngine()
        let player = MusicPlayer(engine: engine)
        var changes = 0
        player.onStateChange = { changes += 1 }
        let start = Date().addingTimeInterval(6)

        engine.emit(.mixCue(.upcoming(startsAt: start)))
        #expect(player.mixCue == .upcoming(startsAt: start))
        engine.emit(.mixCue(.mixing))
        #expect(player.mixCue == .mixing)
        engine.emit(.mixCue(nil))
        #expect(player.mixCue == nil)
        #expect(changes == 0)
    }
}

@MainActor
@Suite("AVPlaybackEngine mix cue")
struct AVPlaybackEngineMixCueTests {
    private func writeTone(_ name: String, seconds: Double) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/mixcue", isDirectory: true)
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

    private func stream(_ name: String, duration: Double, url: URL) -> ResolvedStream {
        ResolvedStream(
            videoId: name, url: url, itag: 140, durationSeconds: duration,
            expiresAt: .distantFuture, playbackTrackingURL: nil, httpHeaders: [:]
        )
    }

    /// A real chain held silent, so nothing is heard.
    private func silentEngine(crossfade: TimeInterval) -> AVPlaybackEngine {
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)
        let engine = AVPlaybackEngine(chain: chain)
        engine.crossfadeSeconds = crossfade
        return engine
    }

    private static func cues(in events: [PlaybackEngineEvent]) -> [MusicMixCue?] {
        events.compactMap { if case .mixCue(let cue) = $0 { return .some(cue) } else { return nil } }
    }

    @Test("a scheduled crossfade: upcoming at least 5 s ahead, mixing at the flip, nothing once drained")
    func scheduledCrossfade() async throws {
        let first = try await writeTone("m1", seconds: 12)
        let second = try await writeTone("m2", seconds: 8)
        let engine = silentEngine(crossfade: 2)
        var events: [PlaybackEngineEvent] = []
        var upcomingSentAt: Date?
        var flippedAt: Date?
        engine.onEvent = { event in
            events.append(event)
            if case .mixCue(.upcoming) = event, upcomingSentAt == nil { upcomingSentAt = Date() }
            if case .advanced = event { flippedAt = Date() }
        }
        engine.load(stream("m1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("m2", duration: 8, url: second))

        let advanced = await waitUntil(timeout: .seconds(40)) { events.contains(.advanced(videoId: "m2")) }
        #expect(advanced, "events: \(events)")
        let drained = await waitUntil(timeout: .seconds(20)) { !engine.isCrossfading }
        #expect(drained)

        let cues = Self.cues(in: events)
        #expect(cues.count == 3, "cues: \(cues)")
        guard cues.count == 3, case .upcoming(let startsAt)?? = cues.first else { return }
        #expect(cues[1] == .mixing)
        #expect(cues[2] == nil)
        // The cue comes early enough for the label's 5 s, and names the overlap's real start.
        let sent = try #require(upcomingSentAt)
        let flipped = try #require(flippedAt)
        #expect(startsAt.timeIntervalSince(sent) >= MusicMixCue.lead, "the overlap was known \(startsAt.timeIntervalSince(sent)) s ahead")
        #expect(abs(flipped.timeIntervalSince(startsAt)) < 0.6, "the flip came \(flipped.timeIntervalSince(startsAt)) s off the cue")
        // Mixing is sent before the identity flips, so the label never blinks off between the two songs.
        let mixingIndex = try #require(events.firstIndex(of: .mixCue(.mixing)))
        let advancedIndex = try #require(events.firstIndex(of: .advanced(videoId: "m2")))
        #expect(mixingIndex < advancedIndex)
        #expect(engine.mixCue == nil)
    }

    @Test("with Crossfade at 0 the gapless switch sends no cue")
    func gaplessSendsNone() async throws {
        let first = try await writeTone("n1", seconds: 4)
        let second = try await writeTone("n2", seconds: 4)
        let engine = silentEngine(crossfade: 0)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("n1", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("n2", duration: 4, url: second))
        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "n2")) }
        #expect(advanced)
        #expect(Self.cues(in: events).isEmpty, "events: \(events)")
    }

    @Test("a pause withdraws an upcoming cue and play brings it back")
    func pauseWithdraws() async throws {
        let first = try await writeTone("q1", seconds: 12)
        let second = try await writeTone("q2", seconds: 8)
        let engine = silentEngine(crossfade: 2)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("q1", duration: 12, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("q2", duration: 8, url: second))

        let upcoming = await waitUntil(timeout: .seconds(30)) {
            if case .upcoming = engine.mixCue { return true } else { return false }
        }
        #expect(upcoming)
        engine.pause()
        #expect(engine.mixCue == nil)
        #expect(Self.cues(in: events).last == .some(nil))

        engine.play()
        let again = await waitUntil(timeout: .seconds(10)) {
            if case .upcoming = engine.mixCue { return true } else { return false }
        }
        #expect(again, "events: \(events)")
    }

    @Test("a manual skip onto the preload is no mix: no cue")
    func manualSkipSendsNone() async throws {
        let first = try await writeTone("k1", seconds: 30)
        let second = try await writeTone("k2", seconds: 8)
        let engine = silentEngine(crossfade: 2)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("k1", duration: 30, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("k2", duration: 8, url: second))

        let ready = await waitUntil(timeout: .seconds(30)) { engine.canCrossfadeToPreloaded }
        #expect(ready)
        #expect(engine.crossfadeToPreloaded(seconds: 0.3))
        #expect(engine.isCrossfading)
        let drained = await waitUntil(timeout: .seconds(5)) { !engine.isCrossfading }
        #expect(drained)
        #expect(Self.cues(in: events).isEmpty, "events: \(events)")
    }
}
