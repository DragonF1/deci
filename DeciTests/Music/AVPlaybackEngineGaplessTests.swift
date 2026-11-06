// DeciTests/Music/AVPlaybackEngineGaplessTests.swift
// The engine's two decks: the standby deck's item is built the same way as the active one's (its own tap mix), it never
// disturbs the active deck, it is thrown away on any cancel, and a real active item that ends hands over to a real
// preloaded one with an "advanced" event instead of an "ended" one. Most items point at files that do not exist, so
// nothing is fetched; the one real playback test is muted (the fallback level) and uses short tone files.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine decks")
struct AVPlaybackEngineGaplessTests {
    private func stream(_ name: String, duration: Double? = 200, url: URL? = nil) -> ResolvedStream {
        ResolvedStream(
            videoId: name,
            url: url ?? URL(fileURLWithPath: "/nonexistent/deci-tests/\(name).m4a"),
            itag: 140,
            durationSeconds: duration,
            expiresAt: .distantFuture,
            playbackTrackingURL: nil,
            httpHeaders: [:]
        )
    }

    private final class Seen {
        var roles: [MusicTapDeck.Role?] = []
        var assets: [URL?] = []
    }

    // MARK: - Preload bookkeeping

    @Test("preload records the track, cancel and a cold load drop it")
    func preloadStateFollowsTheCalls() {
        let engine = AVPlaybackEngine()
        #expect(engine.preloadedVideoId == nil)

        engine.preload(stream("next"))
        #expect(engine.preloadedVideoId == "next")
        engine.cancelPreload()
        #expect(engine.preloadedVideoId == nil)

        engine.preload(stream("next"))
        engine.load(stream("cold"), startAt: 0, autoplay: false)
        #expect(engine.preloadedVideoId == nil, "a load of another track makes the preload stale")

        engine.preload(stream("next"))
        engine.unload()
        #expect(engine.preloadedVideoId == nil)
    }

    @Test("a second preload replaces the first")
    func secondPreloadReplaces() {
        let engine = AVPlaybackEngine()
        engine.preload(stream("one"))
        engine.preload(stream("two"))
        #expect(engine.preloadedVideoId == "two")
    }

    @Test("the standby's mix is built by the same builder, for its own asset, on the standby deck's handle")
    func standbyUsesTheSameMixPath() async {
        let seen = Seen()
        let chain = MusicDSPChain(sampleRate: 48_000)
        let engine = AVPlaybackEngine(chain: chain, makeMix: { asset, _, _ in
            seen.roles.append(MusicAudioTap.currentDeck?.role)
            seen.assets.append((asset as? AVURLAsset)?.url)
            return AVMutableAudioMix()
        })
        engine.load(stream("active"), startAt: 0, autoplay: false)
        engine.preload(stream("standby"))
        let built = await waitUntil(timeout: .seconds(10)) { seen.roles.count == 2 }
        #expect(built)
        #expect(seen.roles.contains(.active))
        #expect(seen.roles.contains(.standby))
        #expect(seen.assets.contains(URL(fileURLWithPath: "/nonexistent/deci-tests/standby.m4a")))
    }

    @Test("preloading never touches the active deck's item")
    func preloadLeavesTheActiveDeckAlone() async {
        let engine = AVPlaybackEngine()
        engine.load(stream("active"), startAt: 0, autoplay: false)
        let item = engine.currentItem
        #expect(item != nil)
        engine.preload(stream("standby"))
        #expect(engine.currentItem === item)
        engine.cancelPreload()
        #expect(engine.currentItem === item)
    }

    @Test("the standby waits without automatic stall waiting, and the active deck keeps it")
    func stallWaitingFlags() async {
        let engine = AVPlaybackEngine()
        engine.load(stream("active"), startAt: 0, autoplay: false)
        // Scrambled first: the flag must be what the preload sets, not what the init left.
        engine.standbyAvPlayer.automaticallyWaitsToMinimizeStalling = true
        engine.preload(stream("standby"))
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling)
        #expect(engine.standbyAvPlayer.automaticallyWaitsToMinimizeStalling == false)
    }

    // MARK: - Output and level reach both decks

    @Test("the output device is set on both decks, including a multi-output aggregate")
    func outputDeviceReachesBoth() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "aggregate-uid")
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == "aggregate-uid")
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == "aggregate-uid")

        engine.setOutputDevice(uid: nil)
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == nil)
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == nil)
    }

    @Test("the fallback volume and mute reach both decks")
    func fallbackLevelReachesBoth() {
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0.4, muted: true)
        for player in [engine.avPlayer, engine.standbyAvPlayer] {
            #expect(player.volume == 0.4)
            #expect(player.isMuted)
        }
    }

    @Test("a standby set up after the level and device were chosen starts with them")
    func laterStandbyInherits() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "device")
        engine.setFallbackLevel(volume: 0.25, muted: false)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        // Scrambled first: the level must be what the preload applies, not what was set on the idle player.
        engine.standbyAvPlayer.volume = 1
        engine.standbyAvPlayer.audioOutputDeviceUniqueID = nil
        engine.preload(stream("two"))
        #expect(engine.standbyAvPlayer.audioOutputDeviceUniqueID == "device")
        #expect(engine.standbyAvPlayer.volume == 0.25)
    }

    // MARK: - Real playback

    private func writeTone(_ name: String, seconds: Double, rate: Double = 44_100) async throws -> URL {
        let directory = URL(fileURLWithPath: "/Volumes/Storage/_test/deci/gapless", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name)-\(UUID().uuidString).m4a")
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

    @Test("a real item that ends hands over to the preloaded one: advanced, never ended")
    func realGaplessAdvance() async throws {
        let first = try await writeTone("a", seconds: 2)
        let second = try await writeTone("b", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)

        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }

        engine.load(stream("a", duration: 2, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("b", duration: 2, url: second))

        let advanced = await waitUntil(timeout: .seconds(20)) {
            events.contains(.advanced(videoId: "b"))
        }
        #expect(advanced, "events: \(events)")
        #expect(!events.contains(.ended), "the first item's end is the hand-over, not an end of playback")
        #expect(engine.preloadedVideoId == nil)
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url == second)
        #expect(engine.avPlayer.automaticallyWaitsToMinimizeStalling, "the new active deck waits for stalls again")
        #expect(engine.scheduledAdvanceCount == 1, "the standby started on its scheduled host time, not at the notification")
        #expect(engine.fallbackAdvanceCount == 0)
        #expect(engine.lateStartCount == 0)

        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended, "the second item ends the playback")
    }

    @Test("a pause on the active deck holds the hand-over until it plays again")
    func pauseHoldsTheHandOver() async throws {
        let first = try await writeTone("c", seconds: 3)
        let second = try await writeTone("d", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }

        var prerolled = false
        engine.onStandbyPrerolled = { finished in if finished { prerolled = true } }
        engine.load(stream("c", duration: 3, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("d", duration: 2, url: second))
        let ready = await waitUntil(timeout: .seconds(20)) { engine.position > 0.3 && prerolled }
        #expect(ready)
        engine.pause()
        #expect(engine.scheduledStartHost == nil, "the pause takes the scheduled start back")
        #expect(engine.standbyAvPlayer.rate == 0)
        #expect(engine.preloadedVideoId == "d", "the preload itself stays")
        #expect(!events.contains(.advanced(videoId: "d")), "a paused track does not hand over")
        #expect(!events.contains(.ended))

        engine.play()
        let advanced = await waitUntil(timeout: .seconds(20)) { events.contains(.advanced(videoId: "d")) }
        #expect(advanced)
    }

    @Test("without a preload the end of the item is reported as ended")
    func endedWithoutPreload() async throws {
        let only = try await writeTone("e", seconds: 1)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("e", duration: 1, url: only), startAt: 0, autoplay: true)
        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended)
    }

    @Test("a cancelled preload leaves the end of the item as ended")
    func cancelledPreloadEndsNormally() async throws {
        let first = try await writeTone("f", seconds: 1)
        let second = try await writeTone("g", seconds: 1)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("f", duration: 1, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("g", duration: 1, url: second))
        engine.cancelPreload()
        let ended = await waitUntil(timeout: .seconds(20)) { events.contains(.ended) }
        #expect(ended)
        #expect(!events.contains(.advanced(videoId: "g")))
    }

    // MARK: - Real playback through the real DSP chain

    private func line(_ label: String, _ c: MusicRenderLease.DebugCounters?) -> String {
        guard let c else { return "\(label): no lease" }
        return "\(label): calls=\(c.calls) full=\(c.fullFrames) gainOnly=\(c.gainOnlyFrames) silenced=\(c.silencedFrames)"
    }

    @Test("real chain: the standby's tap is measured while paused, then the new deck owns the chain with nothing silenced")
    func realChainHandOver() async throws {
        let first = try await writeTone("h", seconds: 4)
        let second = try await writeTone("i", seconds: 4, rate: 48_000)
        let chain = MusicDSPChain(sampleRate: 48_000)
        chain.setTargetGain(0, snap: true)   // the tap applies the gain: nothing is heard
        let engine = AVPlaybackEngine(chain: chain)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        var prerolled = false
        engine.onStandbyPrerolled = { finished in if finished { prerolled = true } }

        engine.load(stream("h", duration: 4, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("i", duration: 4, url: second))
        let ready = await waitUntil(timeout: .seconds(30)) { prerolled && engine.debugStandbyTap?.debugLease != nil }
        #expect(ready, "the standby prepared its tap and prerolled")
        let standbyLease = try #require(engine.debugStandbyTap?.debugLease)
        let activeLease = try #require(engine.debugActiveTap?.debugLease)
        var report: [String] = []
        report.append(line("standby at preroll completion", standbyLease.debugCounters))
        #expect(chain.owns(activeLease))
        #expect(!chain.owns(standbyLease), "preparing the standby never takes the chain")
        #expect(chain.processorSampleRate == 44_100, "nor does it rebuild the owner's processors for its own (48 kHz) rate")
        #expect(chain.processorsReady(for: activeLease), "the owner keeps EQ, AutoEQ and loudness while the standby is prepared")

        try? await Task.sleep(for: .milliseconds(400))
        report.append(line("standby 400 ms later, still paused", standbyLease.debugCounters))
        let pausedFrames = standbyLease.debugCounters
        #expect(pausedFrames.silencedFrames == 0, "no frame of the incoming track is silenced while it is paused")
        #expect(pausedFrames.fullFrames == 0, "an unarmed standby never renders through the shared filters")

        let scheduled = await waitUntil(timeout: .seconds(30)) { engine.scheduledStartHost != nil }
        #expect(scheduled)
        report.append(line("standby when scheduled", standbyLease.debugCounters))
        report.append(line("active when standby scheduled", activeLease.debugCounters))

        let advanced = await waitUntil(timeout: .seconds(30)) { events.contains(.advanced(videoId: "i")) }
        #expect(advanced, "events: \(events)")
        report.append(line("standby at advance", standbyLease.debugCounters))
        #expect(engine.scheduledAdvanceCount == 1)
        #expect(chain.owns(standbyLease), "the new deck's lease owns the chain")
        #expect(!chain.owns(activeLease))

        let before = chain.framesProcessed
        let played = await waitUntil(timeout: .seconds(30)) { engine.position > 0.6 }
        #expect(played)
        #expect(chain.framesProcessed > before, "the chain keeps processing after the hand-over")
        #expect(standbyLease.debugCounters.silencedFrames == 0, "no incoming frame was silenced")
        #expect(chain.processorSampleRate == 48_000, "the processors follow the new track's rate once it owns the chain")
        #expect(chain.processorsReady(for: standbyLease))
        report.append(line("new owner after 0.6 s", standbyLease.debugCounters))
        report.append(line("old deck's lease", activeLease.debugCounters))
        try report.joined(separator: "\n").write(
            toFile: "/Volumes/Storage/_test/deci/gapless/measure.txt", atomically: true, encoding: .utf8
        )
    }

    @Test("a hand-over whose standby never started still plays the next track: the end notification starts it")
    func standbyThatDidNotStartIsStartedAtTheEnd() async throws {
        let first = try await writeTone("j", seconds: 2)
        let second = try await writeTone("k", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        var prerolled = false
        engine.onStandbyPrerolled = { finished in if finished { prerolled = true } }
        engine.load(stream("j", duration: 2, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("k", duration: 2, url: second))
        _ = await waitUntil(timeout: .seconds(20)) { prerolled && engine.scheduledStartHost != nil && engine.position > 1.6 }
        // Something stopped the standby after it was scheduled (a stall, an output change), too late to be scheduled again.
        engine.standbyAvPlayer.pause()
        let rateAfterPause = engine.standbyAvPlayer.rate

        let advanced = await waitUntil(timeout: .seconds(20)) { events.contains(.advanced(videoId: "k")) }
        #expect(advanced)
        #expect(
            engine.lateStartCount + engine.fallbackAdvanceCount == 1,
            "the engine started it itself (rate after pause \(rateAfterPause), scheduled \(engine.scheduledAdvanceCount))"
        )
        let moving = await waitUntil(timeout: .seconds(20)) { engine.avPlayer.rate != 0 && engine.position > 0.3 }
        #expect(moving, "no dead air: the new active deck is playing")
    }

    @Test("a standby that was scheduled is moved when the output device changes, and the hand-over still happens")
    func outputChangeKeepsTheHandOver() async throws {
        let first = try await writeTone("l", seconds: 3)
        let second = try await writeTone("m", seconds: 2)
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0, muted: true)
        var events: [PlaybackEngineEvent] = []
        engine.onEvent = { events.append($0) }
        engine.load(stream("l", duration: 3, url: first), startAt: 0, autoplay: true)
        engine.preload(stream("m", duration: 2, url: second))
        _ = await waitUntil(timeout: .seconds(20)) { engine.scheduledStartHost != nil }
        engine.setOutputDevice(uid: nil)
        let advanced = await waitUntil(timeout: .seconds(20)) { events.contains(.advanced(videoId: "m")) }
        #expect(advanced)
        let moving = await waitUntil(timeout: .seconds(20)) { engine.position > 0.3 }
        #expect(moving)
    }
}
