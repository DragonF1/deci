// DeciTests/Music/AVPlaybackEngineTapTests.swift
// How AVPlaybackEngine puts the tap on an item: the audio mix is on the item before the player gets it, a load that
// finishes late is dropped, and a tap that cannot be built still plays the track unprocessed. Items point at files
// that do not exist, so nothing is fetched and nothing is audible; the engine is never asked to play.

import Foundation
import AVFoundation
import Testing
@testable import Deci

/// Lets a test hold a mix build until it says go.
@MainActor
final class MixGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = continuations
        continuations.removeAll()
        for continuation in waiting { continuation.resume() }
    }
}

@MainActor
@Suite("AVPlaybackEngine tap attachment")
struct AVPlaybackEngineTapTests {
    private struct Installed {
        let url: URL?
        let mix: AVAudioMix?
    }

    private func stream(_ name: String) -> ResolvedStream {
        ResolvedStream(
            videoId: name,
            url: URL(fileURLWithPath: "/nonexistent/deci-tests/\(name).m4a"),
            itag: 140,
            durationSeconds: 200,
            expiresAt: .distantFuture,
            playbackTrackingURL: nil,
            httpHeaders: [:]
        )
    }

    private final class Recorder {
        var installed: [Installed] = []
    }

    private func makeEngine(
        chain: MusicDSPChain? = MusicDSPChain(sampleRate: 48_000),
        recorder: Recorder,
        mixTimeout: Duration = .seconds(5),
        makeMix: @escaping AVPlaybackEngine.MixBuilder
    ) -> AVPlaybackEngine {
        let engine = AVPlaybackEngine(chain: chain, makeMix: makeMix, mixTimeout: mixTimeout)
        engine.willInstall = { item in
            recorder.installed.append(Installed(url: (item.asset as? AVURLAsset)?.url, mix: item.audioMix))
        }
        return engine
    }

    // MARK: - Order

    @Test("the mix is on the item before the player is handed it, and not a moment earlier than the tracks load")
    func mixIsAttachedBeforeReplaceCurrentItem() async {
        let recorder = Recorder()
        // The player item keeps a copy of the mix, not the object, so the mix is recognised by what it carries.
        let markerParameters = AVMutableAudioMixInputParameters()
        markerParameters.trackID = 77
        let marker = AVMutableAudioMix()
        marker.inputParameters = [markerParameters]
        let gate = MixGate()
        let engine = makeEngine(recorder: recorder) { _, _, _ in
            await gate.wait()
            return marker
        }

        engine.load(stream("one"), startAt: 0, autoplay: false)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.installed.isEmpty, "the item must not reach the player while its mix is still being built")
        #expect(engine.currentItem == nil)

        gate.open()
        let installed = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(installed)
        #expect(
            recorder.installed.first?.mix?.inputParameters.first?.trackID == 77,
            "the mix was already on the item at the moment of install"
        )
        #expect(engine.currentItem?.audioMix?.inputParameters.first?.trackID == 77)
    }

    @Test("the mix builder is given the chain and the asset the item plays")
    func mixBuilderGetsTheChainAndAsset() async {
        let recorder = Recorder()
        let chain = MusicDSPChain(sampleRate: 48_000)
        var seenChain: MusicDSPChain?
        var seenURL: URL?
        let engine = makeEngine(chain: chain, recorder: recorder) { asset, chain, _ in
            seenChain = chain
            seenURL = (asset as? AVURLAsset)?.url
            return AVMutableAudioMix()
        }
        let one = stream("one")
        engine.load(one, startAt: 0, autoplay: false)
        _ = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(seenChain === chain)
        #expect(seenURL == one.url)
        #expect(recorder.installed.first?.url == one.url)
    }

    // MARK: - Late loads

    @Test("a load that finishes after a newer load began is dropped")
    func lateLoadIsDropped() async {
        let recorder = Recorder()
        let slowGate = MixGate()
        var finishedSlow = false
        let slow = stream("slow")
        let engine = makeEngine(recorder: recorder) { asset, _, _ in
            if (asset as? AVURLAsset)?.url == slow.url {
                await slowGate.wait()
                finishedSlow = true
            }
            return AVMutableAudioMix()
        }

        engine.load(slow, startAt: 0, autoplay: false)
        engine.load(stream("fast"), startAt: 0, autoplay: false)
        let fastIn = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(fastIn)
        #expect(recorder.installed.first?.url?.lastPathComponent == "fast.m4a")

        slowGate.open()
        let slowDone = await waitUntil(timeout: .seconds(10)) { finishedSlow }
        #expect(slowDone)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.installed.count == 1, "the slow item must never replace the newer one")
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent == "fast.m4a")
    }

    @Test("unloading while a load is in flight drops it")
    func unloadDropsAPendingLoad() async {
        let recorder = Recorder()
        let gate = MixGate()
        var finished = false
        let engine = makeEngine(recorder: recorder) { _, _, _ in
            await gate.wait()
            finished = true
            return AVMutableAudioMix()
        }
        engine.load(stream("one"), startAt: 0, autoplay: true)
        engine.unload()
        gate.open()
        _ = await waitUntil(timeout: .seconds(10)) { finished }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(recorder.installed.isEmpty)
        #expect(engine.currentItem == nil)
    }

    // MARK: - Failure

    @Test("a tap that cannot be built still plays the track, unprocessed")
    func tapFailureStillPlays() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _, _ in nil }
        #expect(engine.unprocessedLoadCount == 0)

        engine.load(stream("one"), startAt: 0, autoplay: true)
        let installed = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(installed, "the item is still handed to the player")
        #expect(recorder.installed.first?.mix == nil)
        #expect(engine.unprocessedLoadCount == 1)

        engine.load(stream("two"), startAt: 0, autoplay: true)
        _ = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 2 }
        #expect(engine.unprocessedLoadCount == 2)
    }

    @Test("with no chain the item is installed at once, with no mix")
    func noChainInstallsSynchronously() {
        let recorder = Recorder()
        let engine = AVPlaybackEngine()
        engine.willInstall = { item in
            recorder.installed.append(Installed(url: (item.asset as? AVURLAsset)?.url, mix: item.audioMix))
        }
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(recorder.installed.count == 1)
        #expect(recorder.installed.first?.mix == nil)
        #expect(engine.unprocessedLoadCount == 0, "an engine without a chain is not a failure")
    }

    // MARK: - Output device

    @Test("setOutputDevice sets the player's output device, and nil returns to the system default")
    func outputDevice() {
        let engine = AVPlaybackEngine()
        #expect(engine.outputDeviceUID == nil)
        engine.setOutputDevice(uid: "test-device-uid")
        #expect(engine.outputDeviceUID == "test-device-uid")
        engine.setOutputDevice(uid: nil)
        #expect(engine.outputDeviceUID == nil)
    }

    @Test("the device really reaches the AVPlayer, and nil sends it back to the system default")
    func playerGetsTheDevice() {
        let engine = AVPlaybackEngine()
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == nil)
        engine.setOutputDevice(uid: "test-device-uid")
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == "test-device-uid")
        engine.setOutputDevice(uid: nil)
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == nil)
    }

    @Test("an empty device UID means the default output, never an empty-named device")
    func emptyUIDIsTheDefault() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "test-device-uid")
        engine.setOutputDevice(uid: "")
        #expect(engine.outputDeviceUID == nil)
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == nil, "an empty name would play to no device")
    }

    @Test("the output device survives loading another item")
    func outputDeviceSurvivesALoad() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _, _ in AVMutableAudioMix() }
        engine.setOutputDevice(uid: "test-device-uid")
        engine.load(stream("one"), startAt: 0, autoplay: false)
        engine.load(stream("two"), startAt: 0, autoplay: false)
        _ = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(engine.outputDeviceUID == "test-device-uid")
        #expect(engine.avPlayer.audioOutputDeviceUniqueID == "test-device-uid")
    }

    // MARK: - Level without the tap

    private func installed(_ recorder: Recorder, count: Int = 1) async -> Bool {
        await waitUntil(timeout: .seconds(10)) { recorder.installed.count == count }
    }

    @Test("an item that plays unprocessed uses the player's own volume and mute, so a muted row stays silent")
    func unprocessedItemUsesThePlayersLevel() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _, _ in nil }
        engine.setFallbackLevel(volume: 0.3, muted: false)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))
        #expect(abs(engine.avPlayer.volume - 0.3) < 1e-6)
        #expect(!engine.avPlayer.isMuted)

        engine.setFallbackLevel(volume: 0.3, muted: true)
        #expect(engine.avPlayer.isMuted)
        engine.setFallbackLevel(volume: 0.8, muted: false)
        #expect(abs(engine.avPlayer.volume - 0.8) < 1e-6)
        #expect(!engine.avPlayer.isMuted)
    }

    @Test("a mute set before the item even loads holds when an unprocessed item arrives")
    func muteBeforeLoadHolds() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _, _ in nil }
        engine.setFallbackLevel(volume: 1, muted: true)
        engine.load(stream("one"), startAt: 0, autoplay: true)
        #expect(await installed(recorder))
        #expect(engine.avPlayer.isMuted)
    }

    @Test("an item with the tap keeps the player at unity and unmuted: the tap does the work, never twice")
    func tappedItemKeepsThePlayerAtUnity() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _, _ in AVMutableAudioMix() }
        engine.setFallbackLevel(volume: 0.3, muted: true)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))
        #expect(engine.avPlayer.volume == 1)
        #expect(!engine.avPlayer.isMuted)

        engine.setFallbackLevel(volume: 0.5, muted: true)
        #expect(engine.avPlayer.volume == 1, "the tap already applies the volume")
        #expect(!engine.avPlayer.isMuted)
    }

    @Test("a processed item after an unprocessed one takes the player back to unity")
    func processedItemResetsTheLevel() async {
        let recorder = Recorder()
        // The first item has no tap, the second does.
        let engine = makeEngine(recorder: recorder) { _, _, _ in recorder.installed.isEmpty ? nil : AVMutableAudioMix() }
        engine.setFallbackLevel(volume: 0.3, muted: true)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))
        #expect(engine.avPlayer.isMuted)

        engine.load(stream("two"), startAt: 0, autoplay: false)
        #expect(await installed(recorder, count: 2))
        #expect(engine.avPlayer.volume == 1)
        #expect(!engine.avPlayer.isMuted)
    }

    @Test("a tap that finds a format it cannot process hands the item over to the player's level")
    func passThroughFallsBack() async throws {
        let recorder = Recorder()
        var report: (@Sendable () -> Void)?
        let engine = makeEngine(recorder: recorder) { _, _, onPassThrough in
            report = onPassThrough
            return AVMutableAudioMix()
        }
        engine.setFallbackLevel(volume: 0.3, muted: true)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))
        #expect(!engine.avPlayer.isMuted, "while the tap is trusted, the player stays out of it")

        // The tap's prepare callback runs on whatever thread Core Audio picked.
        let callback = try #require(report)
        DispatchQueue.global().async { callback() }
        #expect(await waitUntil(timeout: .seconds(10)) { engine.avPlayer.isMuted })
        #expect(abs(engine.avPlayer.volume - 0.3) < 1e-6)
    }

    @Test("a pass-through report from an item that was replaced is ignored")
    func stalePassThroughIsIgnored() async throws {
        let recorder = Recorder()
        var reports: [@Sendable () -> Void] = []
        let engine = makeEngine(recorder: recorder) { _, _, onPassThrough in
            reports.append(onPassThrough)
            return AVMutableAudioMix()
        }
        engine.setFallbackLevel(volume: 0.3, muted: true)
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))
        engine.load(stream("two"), startAt: 0, autoplay: false)
        #expect(await installed(recorder, count: 2))
        #expect(reports.count == 2)

        reports[0]()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!engine.avPlayer.isMuted, "the old item's tap says nothing about the new one")

        reports[1]()
        #expect(await waitUntil(timeout: .seconds(10)) { engine.avPlayer.isMuted })
    }

    @Test("the player's level is clamped to 0...1, boost cannot apply, and a non-finite volume is ignored")
    func fallbackLevelIsContained() {
        let engine = AVPlaybackEngine()
        engine.setFallbackLevel(volume: 0.4, muted: false)
        engine.setFallbackLevel(volume: .nan, muted: false)
        #expect(abs(engine.avPlayer.volume - 0.4) < 1e-6)
        engine.setFallbackLevel(volume: .infinity, muted: false)
        #expect(abs(engine.avPlayer.volume - 0.4) < 1e-6)
        engine.setFallbackLevel(volume: 7, muted: false)
        #expect(engine.avPlayer.volume == 1)
        engine.setFallbackLevel(volume: -2, muted: false)
        #expect(engine.avPlayer.volume == 0)
    }

    // MARK: - Hung loads

    @Test("a mix that takes too long is given up on: the item plays unprocessed rather than not at all")
    func slowMixTimesOut() async {
        let recorder = Recorder()
        let gate = MixGate()
        let engine = makeEngine(recorder: recorder, mixTimeout: .milliseconds(100)) { _, _, _ in
            await gate.wait()
            return AVMutableAudioMix()
        }
        engine.setFallbackLevel(volume: 0.3, muted: false)
        engine.load(stream("one"), startAt: 0, autoplay: true)

        #expect(await installed(recorder), "playback is never blocked on the tap")
        #expect(recorder.installed.first?.mix == nil)
        #expect(engine.unprocessedLoadCount == 1)
        #expect(abs(engine.avPlayer.volume - 0.3) < 1e-6, "an unprocessed item falls back to the player's level")

        // The mix that turns up after all must not be put on an item that is already playing.
        gate.open()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(recorder.installed.count == 1)
        #expect(engine.currentItem?.audioMix == nil)
        #expect(engine.unprocessedLoadCount == 1)
    }

    @Test("a mix that arrives in time is not cut short by the timeout")
    func fastMixIsKept() async {
        let recorder = Recorder()
        let markerParameters = AVMutableAudioMixInputParameters()
        markerParameters.trackID = 77
        let marker = AVMutableAudioMix()
        marker.inputParameters = [markerParameters]
        let engine = makeEngine(recorder: recorder, mixTimeout: .milliseconds(300)) { _, _, _ in marker }
        engine.load(stream("one"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))

        try? await Task.sleep(for: .milliseconds(450))
        #expect(recorder.installed.count == 1, "the timeout of a finished load does nothing")
        #expect(engine.unprocessedLoadCount == 0)
        #expect(engine.currentItem?.audioMix?.inputParameters.first?.trackID == 77)
    }

    @Test("the timeout of a load that was replaced installs nothing")
    func staleTimeoutIsIgnored() async {
        let recorder = Recorder()
        let gate = MixGate()
        let slow = stream("slow")
        let engine = makeEngine(recorder: recorder, mixTimeout: .milliseconds(150)) { asset, _, _ in
            if (asset as? AVURLAsset)?.url == slow.url { await gate.wait() }
            return AVMutableAudioMix()
        }
        engine.load(slow, startAt: 0, autoplay: false)
        engine.load(stream("fast"), startAt: 0, autoplay: false)
        #expect(await installed(recorder))

        try? await Task.sleep(for: .milliseconds(350))
        #expect(recorder.installed.count == 1)
        #expect((engine.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent == "fast.m4a")
        #expect(engine.unprocessedLoadCount == 0)
        gate.open()
    }

    @Test("unloading while a load is in flight drops it for good, even when its timeout comes")
    func unloadBeatsTheTimeout() async {
        let recorder = Recorder()
        let gate = MixGate()
        let engine = makeEngine(recorder: recorder, mixTimeout: .milliseconds(100)) { _, _, _ in
            await gate.wait()
            return AVMutableAudioMix()
        }
        engine.load(stream("one"), startAt: 0, autoplay: true)
        engine.unload()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(recorder.installed.isEmpty)
        #expect(engine.currentItem == nil)
        #expect(engine.unprocessedLoadCount == 0)
        gate.open()
    }
}
