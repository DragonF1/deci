// DeciTests/Music/AVPlaybackEngineTests.swift
// The length the engine trusts: the stream's own duration, never AVFoundation's doubled one.

import Foundation
import Testing
@testable import Deci

@Suite("AVPlaybackEngine")
struct AVPlaybackEngineTests {
    @Test("the stream's duration is the known length")
    func knownDuration() {
        #expect(AVPlaybackEngine.knownDuration(of: MusicSamples.stream(duration: 210.373)) == 210.373)
    }

    @Test("a missing, zero, negative or non-finite stream duration is unknown, never replaced by the item's doubled one")
    func unknownDuration() {
        for duration in [nil, 0, -5, .infinity, .nan] as [Double?] {
            #expect(AVPlaybackEngine.knownDuration(of: MusicSamples.stream(duration: duration)) == nil)
        }
    }
}
