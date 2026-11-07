// DeciTests/Music/BeatSync/AVPlaybackEngineAlignedStartTests.swift
// The guards of the tier 3b seam: `startStandby(atHostTime:rate:)` and `hostTime(ofActiveItemTime:)`. Nothing plays here
// (the items point at files that do not exist). The seam running on real decks is the opt-in beat sync spike.

import Foundation
import AVFoundation
import CoreMedia
import Testing
@testable import Deci

@MainActor
@Suite("AVPlaybackEngine aligned start")
struct AVPlaybackEngineAlignedStartTests {
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

    private var soon: CMTime {
        CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: 2, preferredTimescale: 1_000_000))
    }

    @Test("with nothing preloaded the start is refused and the standby is left alone")
    func refusedWithoutPreload() {
        let engine = AVPlaybackEngine()
        #expect(engine.startStandby(atHostTime: soon, rate: 1) == false)
        #expect(engine.standbyAvPlayer.rate == 0)
    }

    @Test("a preload that is not ready yet is refused")
    func refusedWhileNotReady() {
        let engine = AVPlaybackEngine()
        engine.load(stream("active"), startAt: 0, autoplay: false)
        engine.preload(stream("standby"))
        #expect(engine.preloadIsReady == false)
        #expect(engine.startStandby(atHostTime: soon, rate: 1) == false)
        #expect(engine.standbyAvPlayer.rate == 0)
    }

    @Test("an unusable rate or host time is refused before anything else is looked at")
    func refusedForBadArguments() {
        let engine = AVPlaybackEngine()
        for rate: Float in [0, -1, .nan, .infinity] {
            #expect(engine.startStandby(atHostTime: soon, rate: rate) == false, "rate \(rate)")
        }
        #expect(engine.startStandby(atHostTime: .invalid, rate: 1) == false)
        #expect(engine.startStandby(atHostTime: .indefinite, rate: 1) == false)
    }

    @Test("the host time of an item time is nil while the active deck is not playing")
    func noHostTimeWhenNotPlaying() {
        let engine = AVPlaybackEngine()
        #expect(engine.hostTime(ofActiveItemTime: 10) == nil, "no item")
        engine.load(stream("active"), startAt: 0, autoplay: false)
        #expect(engine.hostTime(ofActiveItemTime: 10) == nil, "an item that is not playing")
        #expect(engine.hostTime(ofActiveItemTime: .nan) == nil)
    }
}
