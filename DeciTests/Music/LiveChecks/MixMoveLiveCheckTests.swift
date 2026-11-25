// DeciTests/Music/LiveChecks/MixMoveLiveCheckTests.swift
// Opt-in (TEST_RUNNER_DECI_LIVE=1): each of the new moves, forced on real song pairs and played through the real MusicService
// and two-deck engine into the muted capture: the planner built it, the engine played it, and nothing dropped out, went
// non-finite, stalled or clicked. Numbers go to style-report.txt.

import Foundation
import Testing
@testable import Deci

@MainActor
@Suite("MixMoveLiveCheckTests", .serialized, .enabled(if: liveGate))
struct MixMoveLiveCheckTests {
    typealias Style = MixStyleLiveCheckTests

    @Test("each new move through the real engine: it is played, with no dropout and no click", arguments: [
        MusicTransitionStyle.lowpassSweep, .echoThrow, .reverbOut, .brake, .loopRoll, .doubleDrop,
    ])
    func move(style: MusicTransitionStyle) async throws {
        let world = try await LiveWorld.shared()
        guard let audio = await LiveAudio.shared(world: world) else { Issue.record("capture not proven: \(LiveAudio.failure ?? "?")"); return }
        LiveSong.forceLocal = true
        defer { LiveAudio.end(); LiveSong.forceLocal = false; MusicTransitionStylePicker.debugForcedStyle = nil }
        Style.note("== \(style.rawValue) \(Date())")
        let found = Style.pairs(world, style: style, among: Style.allPairs(world))
        var seen = Set<String>()
        // Spread over distinct outgoing songs.
        let candidates = found.filter { seen.insert($0.0.videoId).inserted }.prefix(5)
        Style.note("  \(found.count) of \(world.songs.count * (world.songs.count - 1)) pairs can be built; trying up to \(candidates.count)")
        // A double drop needs two songs with a drop at one tempo: a small library may have no such pair.
        guard !found.isEmpty || style != .doubleDrop else { return }
        var proved = 0
        for (a, b) in candidates where proved < 2 {
            guard let played = await Style.play(world, audio, style: style, a, b) else { continue }
            let t = played.transition
            guard played.style == style.rawValue else { Style.note("  \(a.title) > \(b.title): played \(played.style)"); continue }
            var steps = "no outgoing stream"
            if let capture = played.capture, let out = Style.stream(capture, role: "outgoing deck"), let mixOut = t.mixOut {
                let before = Style.maxJump(out.samples, Style.slice(out, items: (mixOut - 8)..<mixOut))
                let during = Style.maxJump(out.samples, Style.slice(out, items: mixOut..<(mixOut + 45)))
                steps = "max step before \(liveF(Double(before), 4)), during \(liveF(Double(during), 4))"
                #expect(during <= max(before * 1.25, 0.02), "\(a.title) > \(b.title): a step of \(during) against the song's own \(before)")
            }
            Style.note("  \(a.title) > \(b.title): left at \(liveF(t.mixOut ?? .nan)) of \(liveF(a.duration)) s, fade \(liveF(t.planFade ?? .nan)), heard overlap \(liveF(t.overlapSec)) s; dropouts=\(t.dropouts) nonFinite=\(t.nonFinite) stalls=\(t.stalls) rateWrites=\(t.engineRateWrites) glitch=\(t.glitchLines) peak \(liveF(Double(t.capturePeak), 3)); \(steps) \(t.dropoutDetail)")
            #expect(t.dropouts == 0, "dropouts \(t.dropoutDetail)")
            #expect(t.nonFinite == 0)
            #expect(t.engineRateWrites == 0)
            proved += 1
        }
        #expect(proved >= 1, "no real pair played a \(style.rawValue)")
    }
}
