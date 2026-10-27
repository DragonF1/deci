// DeciTests/Music/AVPlaybackEngineStallTests.swift
// A playback stall (the player ran out of buffered audio) is an audible glitch Deci can see for itself, so the music
// engine writes a [GLITCH] line for it. Items point at files that do not exist, so nothing is fetched and nothing is
// audible; the stall is posted by hand, the way AVFoundation posts it for the item.

import Foundation
import AVFoundation
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine stall logging")
struct AVPlaybackEngineStallTests {
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
        var lines: [String] = []
        var items: [AVPlayerItem] = []
    }

    /// An engine without a tap (items install at once) that records the lines it logs and the items it installs.
    private func makeEngine() -> (AVPlaybackEngine, Recorder) {
        let recorder = Recorder()
        let engine = AVPlaybackEngine()
        engine.willInstall = { recorder.items.append($0) }
        engine.onGlitchLine = { recorder.lines.append($0) }
        return (engine, recorder)
    }

    private func stall(_ item: AVPlayerItem) {
        NotificationCenter.default.post(name: AVPlayerItem.playbackStalledNotification, object: item)
    }

    /// The observer delivers on the main queue, so a posted stall lands after the test yields.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    @Test("a stall of the loaded item logs one line in the contract format")
    func stallIsLogged() async {
        let (engine, recorder) = makeEngine()
        engine.load(stream("a"), startAt: 0, autoplay: false)
        guard let item = recorder.items.last else {
            Issue.record("expected the item to be installed")
            return
        }

        stall(item)
        let logged = await waitUntil { recorder.lines.count == 1 }
        #expect(logged)
        #expect(engine.stallCount == 1)

        guard let line = recorder.lines.first else { return }
        let prefix = "[GLITCH] app=\"Deci music\" stalled=1 load="
        #expect(line.hasPrefix(prefix))
        let load = line.dropFirst(prefix.count)
        #expect(Double(load) != nil)
        #expect(load.split(separator: ".").last?.count == 2, "two decimals")
    }

    @Test("every stall is a line of its own")
    func repeatedStalls() async {
        let (engine, recorder) = makeEngine()
        engine.load(stream("a"), startAt: 0, autoplay: false)
        guard let item = recorder.items.last else {
            Issue.record("expected the item to be installed")
            return
        }

        stall(item)
        stall(item)
        stall(item)
        let logged = await waitUntil { recorder.lines.count == 3 }
        #expect(logged)
        #expect(engine.stallCount == 3)
    }

    @Test("a stall of some other item is not this engine's")
    func otherItemIgnored() async {
        let (engine, recorder) = makeEngine()
        engine.load(stream("a"), startAt: 0, autoplay: false)

        let stranger = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/deci-tests/stranger.m4a"))
        stall(stranger)
        await settle()
        #expect(recorder.lines.isEmpty)
        #expect(engine.stallCount == 0)
    }

    @Test("before anything is loaded there is nothing to stall")
    func nothingLoaded() async {
        let (engine, recorder) = makeEngine()
        let stranger = AVPlayerItem(url: URL(fileURLWithPath: "/nonexistent/deci-tests/stranger.m4a"))
        stall(stranger)
        await settle()
        #expect(recorder.lines.isEmpty)
        #expect(engine.stallCount == 0)
    }

    @Test("a stall of the item a newer load replaced is dropped, the new item's is logged")
    func replacedItemIgnored() async {
        let (engine, recorder) = makeEngine()
        engine.load(stream("a"), startAt: 0, autoplay: false)
        engine.load(stream("b"), startAt: 0, autoplay: false)
        guard recorder.items.count == 2 else {
            Issue.record("expected both items to be installed")
            return
        }

        stall(recorder.items[0])
        await settle()
        #expect(recorder.lines.isEmpty, "the old item's observer went with it")

        stall(recorder.items[1])
        let logged = await waitUntil { recorder.lines.count == 1 }
        #expect(logged)
        #expect(engine.stallCount == 1)
    }

    @Test("one observer per loaded item: reloading does not make a stall count twice")
    func noDuplicateObservers() async {
        let (engine, recorder) = makeEngine()
        for name in ["a", "b", "c"] { engine.load(stream(name), startAt: 0, autoplay: false) }
        guard let item = recorder.items.last else {
            Issue.record("expected the item to be installed")
            return
        }

        stall(item)
        let logged = await waitUntil { recorder.lines.count >= 1 }
        #expect(logged)
        await settle()
        #expect(recorder.lines.count == 1)
        #expect(engine.stallCount == 1)
    }
}
