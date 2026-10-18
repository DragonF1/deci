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
        makeMix: @escaping @MainActor (AVAsset, MusicDSPChain) async -> AVAudioMix?
    ) -> AVPlaybackEngine {
        let engine = AVPlaybackEngine(chain: chain, makeMix: makeMix)
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
        let engine = makeEngine(recorder: recorder) { _, _ in
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
        let engine = makeEngine(chain: chain, recorder: recorder) { asset, chain in
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
        let engine = makeEngine(recorder: recorder) { asset, _ in
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
        let engine = makeEngine(recorder: recorder) { _, _ in
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
        let engine = makeEngine(recorder: recorder) { _, _ in nil }
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

    @Test("an empty device UID means the default output, never an empty-named device")
    func emptyUIDIsTheDefault() {
        let engine = AVPlaybackEngine()
        engine.setOutputDevice(uid: "test-device-uid")
        engine.setOutputDevice(uid: "")
        #expect(engine.outputDeviceUID == nil)
    }

    @Test("the output device survives loading another item")
    func outputDeviceSurvivesALoad() async {
        let recorder = Recorder()
        let engine = makeEngine(recorder: recorder) { _, _ in AVMutableAudioMix() }
        engine.setOutputDevice(uid: "test-device-uid")
        engine.load(stream("one"), startAt: 0, autoplay: false)
        engine.load(stream("two"), startAt: 0, autoplay: false)
        _ = await waitUntil(timeout: .seconds(10)) { recorder.installed.count == 1 }
        #expect(engine.outputDeviceUID == "test-device-uid")
    }
}
