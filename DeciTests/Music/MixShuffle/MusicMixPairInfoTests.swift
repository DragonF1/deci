// DeciTests/Music/MixShuffle/MusicMixPairInfoTests.swift
// Tier 4 P3: what Up next shows in Mix for a song: tempo, key and whether the song before it hands over on the beat.

import Foundation
import Testing
@testable import Deci

/// Rows for the Mix tests: a 240 s song with a beat grid at `bpm` and a key.
@MainActor
enum MixRows {
    static func row(
        _ id: String, bpm: Double? = 120, tonic: Int? = 0, minor: Bool = false, keyConfidence: Float = 0.5,
        energy: Float = 0.5
    ) -> MusicAnalysis {
        var row = MusicTransitionPlannerTests.analysis(id, duration: 240, silenceStart: 0.1, silenceEnd: 236, introEnd: 8, outroStart: 200)
        if let bpm {
            row.beatGrid = MusicBeatPlannerTests.grid(period: 60 / bpm, anchor: 0.1, phase: 1, span: 0.1...236).encode()
        }
        if let tonic {
            row.keyInfo = MusicKeyInfo(tonic: tonic, isMinor: minor, confidence: keyConfidence, energy: energy).encode()
        }
        return row
    }

    static func side(_ row: MusicAnalysis) -> MusicTransitionSide {
        MusicTransitionSide(videoId: row.videoId, durationSeconds: 240, analysis: row, youtubeLoudnessDb: nil)
    }
}

@MainActor
@Suite("MusicMixPairInfo")
struct MusicMixPairInfoTests {
    @Test("the row text is the whole tempo and the Camelot key, or whichever is known")
    func rowText() {
        #expect(MusicMixPairInfo(bpm: 128, camelot: "8A", mode: .beat).rowText == "128 \u{00B7} 8A")
        #expect(MusicMixPairInfo(bpm: 128, camelot: nil, mode: .fade).rowText == "128")
        #expect(MusicMixPairInfo(bpm: nil, camelot: "8A", mode: .fade).rowText == "8A")
        #expect(MusicMixPairInfo(bpm: nil, camelot: nil, mode: .fade).rowText == nil)
    }

    @Test("the cache key names the song before and the song after")
    func cacheKey() {
        #expect(MusicMixPairInfo.key(from: "a", to: "b") == "a>b")
        #expect(MusicMixPairInfo.key(from: "a", to: "b") != MusicMixPairInfo.key(from: "b", to: "a"))
    }

    @Test("two songs with trusted grids and matching tempo hand over on the beat")
    func beatPair() {
        let a = MixRows.row("aaaaaaaaaaa", bpm: 120)
        let b = MixRows.row("bbbbbbbbbbb", bpm: 120, tonic: 7, minor: true)
        let info = MusicMixPairInfo.make(outgoing: MixRows.side(a), incoming: MixRows.side(b))
        #expect(info.mode == .beat)
        #expect(info.bpm == 120)
        #expect(info.camelot == b.trustedCamelot)
        #expect(info.camelot != nil)
    }

    @Test("a song without a grid fades, and shows no tempo")
    func noGridFades() {
        let a = MixRows.row("aaaaaaaaaaa", bpm: 120)
        let b = MixRows.row("bbbbbbbbbbb", bpm: nil)
        let info = MusicMixPairInfo.make(outgoing: MixRows.side(a), incoming: MixRows.side(b))
        #expect(info.mode == .fade)
        #expect(info.bpm == nil)
    }

    @Test("a key the detector was unsure of is not shown")
    func untrustedKey() {
        let a = MixRows.row("aaaaaaaaaaa")
        let b = MixRows.row("bbbbbbbbbbb", keyConfidence: 0.01)
        let info = MusicMixPairInfo.make(outgoing: MixRows.side(a), incoming: MixRows.side(b))
        #expect(info.camelot == nil)
    }

    @Test("with beat-matched transitions off every pair fades")
    func beatMixOff() {
        let a = MixRows.row("aaaaaaaaaaa", bpm: 120)
        let b = MixRows.row("bbbbbbbbbbb", bpm: 120)
        let info = MusicMixPairInfo.make(outgoing: MixRows.side(a), incoming: MixRows.side(b), beatMixEnabled: false)
        #expect(info.mode == .fade)
        #expect(info.bpm == 120)
    }

    @Test("the glyph and its name tell a beat mix from a fade")
    func glyphs() {
        let beat = MusicMixPairInfo(bpm: nil, camelot: nil, mode: .beat)
        let fade = MusicMixPairInfo(bpm: nil, camelot: nil, mode: .fade)
        #expect(beat.symbol != fade.symbol)
        #expect(beat.modeLabel == "Beat mix")
        #expect(fade.modeLabel == "Fade")
    }
}
