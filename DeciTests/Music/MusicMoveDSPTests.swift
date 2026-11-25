// DeciTests/Music/MusicMoveDSPTests.swift
// The sound of the new moves: the on and off switch they share, the brake, the loop roll, the reverb out, the echo throw and
// the low-pass sweep. All offline, at 48 kHz.

import Foundation
import Testing
@testable import Deci

@Suite("MusicMoveDSP")
struct MusicMoveDSPTests {
    static let rate = 48_000.0

    static func stereo(_ mono: [Float]) -> [Float] { mono.flatMap { [$0, $0] } }

    static func sine(_ hz: Double, frames: Int, amplitude: Float = 0.5) -> [Float] {
        (0..<frames).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    static func left(_ stereo: [Float]) -> [Float] { stride(from: 0, to: stereo.count, by: 2).map { stereo[$0] } }

    static func rms(_ mono: [Float], _ range: Range<Int>) -> Float {
        let part = mono[range]
        return (part.reduce(Float(0)) { $0 + $1 * $1 } / Float(part.count)).squareRoot()
    }

    static func crossings(_ mono: [Float], _ range: Range<Int>) -> Int {
        zip(mono[range], mono[range].dropFirst()).count { ($0 < 0) != ($1 < 0) }
    }

    /// The biggest jump between two neighbouring samples.
    static func step(_ mono: [Float], _ range: Range<Int>) -> Float {
        zip(mono[range], mono[range].dropFirst()).map { abs($1 - $0) }.max() ?? 0
    }

    // MARK: The switch

    @Test("a run starts once, is released once and is over when the renderer says so")
    func switchRun() {
        let control = MusicEffectSwitch()
        #expect(control.poll() == .init())
        control.begin()
        #expect(control.isActive)
        #expect(control.poll() == .init(isActive: true, starts: true))
        #expect(control.poll() == .init(isActive: true))
        control.release(frames: 480)
        #expect(control.poll() == .init(isActive: true, releaseFrames: 480))
        #expect(control.poll() == .init(isActive: true))
        control.finish()
        #expect(!control.isActive)
        #expect(control.poll() == .init())
    }

    @Test("a release from before a run never ends it, and a run asked for while one ends is not lost")
    func switchEdges() {
        let control = MusicEffectSwitch()
        control.release(frames: 10)
        control.begin()
        #expect(control.poll() == .init(isActive: true, starts: true), "the release was for nothing")
        control.begin()
        control.finish()
        #expect(control.isActive, "the second run is still to come")
        #expect(control.poll() == .init(isActive: true, starts: true))
        control.end()
        #expect(control.poll() == .init())
        control.begin()
        #expect(control.poll().starts)
    }

    // MARK: Brake

    /// What the brake adds to silence.
    static func brake(
        _ input: [Float], cut: Int, length: Int, gain: Float = 1, block: Int = 512, releaseAt: Int? = nil, release: Int = 480
    ) -> (out: [Float], brake: MusicVinylBrake) {
        let brake = MusicVinylBrake(sampleRate: rate)
        brake.begin(MusicBrakeSettings(cutAfterFrames: cut, lengthFrames: length, gain: gain))
        let source = stereo(input)
        var out = [Float](repeating: 0, count: source.count)
        var at = 0
        while at < input.count {
            let frames = min(block, input.count - at)
            if let releaseAt, at >= releaseAt, brake.control.debugReleases.count == 0 { brake.control.release(frames: release) }
            source.withUnsafeBufferPointer { samples in
                out.withUnsafeMutableBufferPointer { mixed in
                    if brake.prepare(samples.baseAddress! + at * 2, frames: frames) {
                        brake.mix(into: mixed.baseAddress! + at * 2, frames: frames)
                    }
                }
            }
            at += frames
        }
        return (left(out), brake)
    }

    @Test("a brake nobody asked for does nothing")
    func brakeIdle() {
        let brake = MusicVinylBrake(sampleRate: Self.rate)
        let input = [Float](repeating: 0.5, count: 1_024)
        #expect(!input.withUnsafeBufferPointer { brake.prepare($0.baseAddress!, frames: 512) })
    }

    @Test("the brake is silent before the cut, sinks in pitch and level after it, and stands still at the end")
    func brakeSinks() {
        let (out, brake) = Self.brake(Self.sine(1_000, frames: 48_000), cut: 4_800, length: 24_000)
        #expect(out[0..<4_800].allSatisfy { $0 == 0 })
        let first = Self.rms(out, 5_000..<10_000), late = Self.rms(out, 23_000..<28_000)
        #expect(abs(first - 0.5 / Float(2).squareRoot()) < 0.02, "it starts as loud as the song, was \(first)")
        #expect(late < first * 0.6)
        // The pitch is the speed: about 0.9 of the song's at a tenth of the way, 0.5 half way.
        let early = Self.crossings(out, 6_000..<8_400), middle = Self.crossings(out, 15_600..<18_000)
        #expect(early > 80 && early < 100, "\(early) crossings where the song has 100")
        #expect(middle > 45 && middle < 55, "\(middle) half way")
        #expect(out[28_800...].allSatisfy { $0 == 0 })
        #expect(!brake.control.isActive)
    }

    @Test("the brake never jumps, at its start or its end")
    func brakeHasNoClicks() {
        // A cosine starts at full level: without the fade in this would be a step of 0.5.
        let input = (0..<40_000).map { 0.5 * Float(cos(2 * Double.pi * 200 * Double($0) / Self.rate)) }
        let (out, _) = Self.brake(input, cut: 2_400, length: 20_000)
        #expect(Self.step(out, 0..<40_000) < 0.02)
    }

    @Test("the brake sounds the same in any block size, and one longer than its recording is made to fit")
    func brakeBlocks() {
        let input = Self.sine(440, frames: 40_000)
        let reference = Self.brake(input, cut: 700, length: 24_000, block: 512).out
        for block in [1, 37, 1_024, 8_192] {
            #expect(Self.brake(input, cut: 700, length: 24_000, block: block).out == reference, "block \(block)")
        }
        let (long, brake) = Self.brake(input, cut: 0, length: 400_000)
        #expect(long.allSatisfy { $0.isFinite })
        #expect(!brake.control.isActive, "over within the longest brake")
    }

    @Test("a release takes the brake out, before the cut at once and after it over its length")
    func brakeRelease() {
        let input = Self.sine(440, frames: 24_000)
        let (early, first) = Self.brake(input, cut: 8_000, length: 16_000, releaseAt: 1_000)
        #expect(early.allSatisfy { $0 == 0 })
        #expect(!first.control.isActive)
        let (late, second) = Self.brake(input, cut: 0, length: 20_000, releaseAt: 5_120, release: 480)
        #expect(Self.rms(late, 4_000..<5_000) > 0.2)
        #expect(late[5_700...].allSatisfy { $0 == 0 })
        #expect(Self.step(late, 5_000..<6_000) < 0.05)
        #expect(!second.control.isActive)
    }

    @Test("what is not a number never gets out of the brake, and the sum stays in range")
    func brakeBounds() {
        var input = [Float](repeating: 0.9, count: 20_000)
        input[3_000] = .nan
        input[3_100] = .infinity
        let (out, _) = Self.brake(input, cut: 0, length: 16_000)
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        // A request with no sense in it is made to fit.
        let brake = MusicVinylBrake(sampleRate: .nan)
        brake.begin(MusicBrakeSettings(cutAfterFrames: -5, lengthFrames: 0, gain: .nan))
        #expect(brake.debugSettings == MusicBrakeSettings(cutAfterFrames: 0, lengthFrames: 1, gain: MusicBrakeSettings.coveredGain))
    }

    // MARK: Loop roll

    static func roll(
        _ input: [Float], start: Int, beat: Int, block: Int = 512, releaseAt: Int? = nil
    ) -> (out: [Float], roll: MusicLoopRoll) {
        let roll = MusicLoopRoll(sampleRate: rate)
        roll.begin(MusicRollSettings(startFrame: start, beatFrames: beat))
        var out = stereo(input)
        var at = 0
        while at < input.count {
            let frames = min(block, input.count - at)
            if let releaseAt, at >= releaseAt, roll.control.debugReleases.count == 0 { roll.control.release(frames: 1_440) }
            out.withUnsafeMutableBufferPointer { roll.process($0.baseAddress! + at * 2, frames: frames) }
            at += frames
        }
        return (left(out), roll)
    }

    @Test("the bar: the first beat, the beat again, its first half twice, its first quarter four times")
    func rollSource() {
        let beat = 8
        #expect((8..<32).map { MusicLoopRoll.source(of: $0, beat: beat) } == [
            0, 1, 2, 3, 4, 5, 6, 7,
            0, 1, 2, 3, 0, 1, 2, 3,
            0, 1, 0, 1, 0, 1, 0, 1,
        ])
        for at in 1_001..<4_004 { #expect((0..<1_001).contains(MusicLoopRoll.source(of: at, beat: 1_001))) }
    }

    @Test("the song plays on until the roll, the bar is built out of its first beat, and the song goes on after it")
    func rollBar() {
        let beat = 4_800, start = 1_000
        // Every sample says where it is from.
        let input = (0..<40_000).map { Float($0) / 50_000 }
        let (out, roll) = Self.roll(input, start: start, beat: beat)
        #expect(Array(out[0..<(start + beat)]) == Array(input[0..<(start + beat)]))
        // Away from the seams (a bridge is 2.5 ms, 120 frames) it is exactly the recording.
        for at in [beat + 500, beat * 2 + 600, beat * 2 + beat / 2 + 600, beat * 3 + 300, beat * 3 + beat / 4 * 3 + 300] {
            #expect(out[start + at] == input[start + MusicLoopRoll.source(of: at, beat: beat)], "at \(at)")
        }
        let end = start + 4 * beat
        #expect(Array(out[(end + 121)...]) == Array(input[(end + 121)...]))
        #expect(!roll.control.isActive)
    }

    @Test("no seam of the roll jumps")
    func rollSeams() {
        let input = Self.sine(333, frames: 40_000)
        let song = Self.step(input, 0..<40_000)
        let (out, _) = Self.roll(input, start: 1_234, beat: 4_801)
        // A bridge of 120 frames takes a jump of at most 1 away, so it adds less than 0.01 per sample.
        #expect(Self.step(out, 0..<40_000) < song + 0.01)
        #expect(out.allSatisfy { abs($0) <= 1.5 })
    }

    @Test("the roll sounds the same in any block size")
    func rollBlocks() {
        let input = Self.sine(250, frames: 30_000)
        let reference = Self.roll(input, start: 900, beat: 4_800).out
        for block in [1, 37, 1_024, 8_192] {
            #expect(Self.roll(input, start: 900, beat: 4_800, block: block).out == reference, "block \(block)")
        }
    }

    @Test("a release drops a roll that has not begun and takes the song back out of one that has")
    func rollRelease() {
        let input = Self.sine(250, frames: 30_000)
        let (untouched, first) = Self.roll(input, start: 8_000, beat: 4_800, releaseAt: 1_000)
        #expect(untouched == input)
        #expect(!first.control.isActive)
        let (out, second) = Self.roll(input, start: 1_000, beat: 4_800, releaseAt: 10_000)
        // The release is seen at the block that starts at 10,240; the bridge is over 120 frames later.
        #expect(Array(out[10_361...]) == Array(input[10_361...]))
        #expect(Self.step(out, 10_000..<11_000) < Self.step(input, 0..<30_000) + 0.01)
        #expect(!second.control.isActive)
    }

    @Test("a beat the roll cannot hold is not rolled")
    func rollLimits() {
        for beat in [0, 3, 48_001, -1] {
            let (out, roll) = Self.roll(Self.sine(250, frames: 4_000), start: 0, beat: beat)
            #expect(out == Self.sine(250, frames: 4_000))
            #expect(roll.control.debugRuns == 0)
        }
        #expect(Self.roll([], start: -1, beat: 4_800).roll.control.debugRuns == 0)
    }

    // MARK: Reverb out

    static func reverb(
        _ input: [Float], cut: Int, tail: Int, block: Int = 512, releaseAt: Int? = nil, release: Int = 480
    ) -> (out: [Float], reverb: MusicReverbTail) {
        let history = MusicEchoDelay(sampleRate: rate, maxBlockFrames: 16_384)
        let reverb = MusicReverbTail(sampleRate: rate)
        reverb.begin(MusicReverbSettings(cutAfterFrames: cut, tailFrames: tail))
        let source = stereo(input)
        var out = [Float](repeating: 0, count: source.count)
        var at = 0
        while at < input.count {
            let frames = min(block, input.count - at)
            if let releaseAt, at >= releaseAt, reverb.control.debugReleases.count == 0 { reverb.control.release(frames: release) }
            source.withUnsafeBufferPointer { history.record($0.baseAddress! + at * 2, frames: frames) }
            if reverb.prepare() {
                out.withUnsafeMutableBufferPointer { reverb.mix(into: $0.baseAddress! + at * 2, frames: frames, history: history) }
            }
            at += frames
        }
        return (left(out), reverb)
    }

    static func noise(_ frames: Int, level: Float = 0.3) -> [Float] {
        var state: UInt64 = 88_172_645_463_325_252
        return (0..<frames).map { _ in
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return (Float(state % 20_001) / 10_000 - 1) * level
        }
    }

    @Test("the tail is silent before the cut, hangs on after it, gets ever quieter and ends")
    func reverbDecays() {
        // The song is cut at 48,000: nothing but the tail is left.
        let input = Self.noise(48_000) + [Float](repeating: 0, count: 130_000)
        let (out, reverb) = Self.reverb(input, cut: 48_000, tail: 120_000)
        #expect(out[0..<48_000].allSatisfy { $0 == 0 })
        let song = Self.rms(input, 0..<48_000)
        let levels = (0..<10).map { Self.rms(out, (48_000 + $0 * 12_000)..<(60_000 + $0 * 12_000)) }
        #expect(levels[0] > song * 0.1 && levels[0] < song, "the tail starts at \(levels[0] / song) of the song")
        for (before, after) in zip(levels, levels.dropFirst()) { #expect(after < before) }
        #expect(levels[4] > song * 0.003, "it is still there half way")
        #expect(levels[9] < levels[0] * 0.05)
        #expect(out[168_000...].allSatisfy { $0 == 0 })
        #expect(!reverb.control.isActive)
    }

    @Test("what the deck plays after the cut is never in the tail")
    func reverbIgnoresWhatFollows() {
        let song = Self.noise(30_000)
        let quiet = Self.reverb(song + [Float](repeating: 0, count: 60_000), cut: 30_000, tail: 48_000).out
        let loud = Self.reverb(song + [Float](repeating: 0.9, count: 60_000), cut: 30_000, tail: 48_000).out
        #expect(quiet == loud)
    }

    @Test("the tail has no bass and comes in without a click")
    func reverbTone() {
        func level(_ hz: Double) -> Float {
            let (out, _) = Self.reverb(Self.sine(hz, frames: 96_000), cut: 48_000, tail: 48_000)
            return Self.rms(out, 50_000..<60_000)
        }
        // The combs ring louder at some pitches than at others, so each side is an average over several.
        let low = [40.0, 50, 60, 70].map(level).reduce(0, +) / 4
        let mid = [700.0, 900, 1_100, 1_400].map(level).reduce(0, +) / 4
        #expect(mid > low * 5, "mid \(mid), low \(low)")
        let (out, _) = Self.reverb(Self.noise(96_000), cut: 48_000, tail: 48_000)
        #expect(abs(out[48_000]) < 0.01)
    }

    @Test("silence rings as silence, and a song full of rubbish rings as something finite")
    func reverbBounds() {
        let silent = Self.reverb([Float](repeating: 0, count: 60_000), cut: 20_000, tail: 30_000).out
        #expect(silent.allSatisfy { $0 == 0 })
        var input = [Float](repeating: 1, count: 60_000)
        for index in stride(from: 10_000, to: 20_000, by: 977) { input[index] = .nan }
        let out = Self.reverb(input, cut: 20_000, tail: 30_000).out
        #expect(out.allSatisfy { $0.isFinite && abs($0) <= 1 })
        let loud = Self.reverb(Self.noise(60_000, level: 1), cut: 20_000, tail: 30_000).out
        #expect(loud.allSatisfy { abs($0) <= 1 })
    }

    @Test("a release takes the tail out over its length, and one before the cut means there is none")
    func reverbRelease() {
        let input = Self.noise(80_000)
        let (out, reverb) = Self.reverb(input, cut: 20_000, tail: 60_000, releaseAt: 30_000, release: 1_440)
        #expect(Self.rms(out, 25_000..<30_000) > 0.01)
        #expect(out[32_000...].allSatisfy { $0 == 0 })
        #expect(!reverb.control.isActive)
        let (none, early) = Self.reverb(input, cut: 20_000, tail: 60_000, releaseAt: 5_000)
        #expect(none.allSatisfy { $0 == 0 })
        #expect(!early.control.isActive)
    }

    @Test("the tail sounds the same in any block size")
    func reverbBlocks() {
        let input = Self.noise(40_000)
        let reference = Self.reverb(input, cut: 20_000, tail: 15_000).out
        for block in [64, 1_024, 4_096] {
            let out = Self.reverb(input, cut: 20_000, tail: 15_000, block: block).out
            #expect(zip(out, reference).allSatisfy { abs($0 - $1) < 1e-4 }, "block \(block)")
        }
    }

    // MARK: Echo throw

    static func throwSettings(delay: Int, cut: Int, isThrow: Bool = true) -> MusicEchoSettings {
        MusicEchoSettings(
            delayFrames: delay, cutAfterFrames: cut, feedback: 0.5, wetGain: 0.5, lowpassHz: 20_000, isThrow: isThrow
        )
    }

    static func echo(_ input: [Float], _ settings: MusicEchoSettings) -> [Float] {
        let echo = MusicEchoDelay(sampleRate: rate, maxBlockFrames: 512)
        echo.start(settings)
        return left(echo.render(dry: stereo(input), faded: stereo(input)))
    }

    @Test("a throw leaves the song alone until the cut, takes it away without a click, and only the repeats are left")
    func throwTakesTheDryAway() {
        let input = Self.sine(1_000, frames: 40_000)
        let out = Self.echo(input, Self.throwSettings(delay: 4_800, cut: 10_000))
        #expect(Array(out[0..<10_000]) == Array(input[0..<10_000]))
        #expect(Self.step(out, 9_900..<10_400) < 0.2)
        // Repeats of half the level each, at 0.5 wet.
        let first = Self.rms(out, 11_000..<14_000), second = Self.rms(out, 15_800..<18_800)
        #expect(abs(first - 0.5 * 0.5 / Float(2).squareRoot()) < 0.03, "the first repeat is at \(first)")
        #expect(abs(second / first - 0.5) < 0.05)
        // An echo out leaves the dry to the deck's own fade.
        let echoOut = Self.echo(input, Self.throwSettings(delay: 4_800, cut: 10_000, isThrow: false))
        #expect(Self.rms(echoOut, 30_000..<35_000) > 0.3)
    }

    @Test("a throw's repeats have no bass: the new song has it by then")
    func throwHasNoBass() {
        let bass = Self.sine(50, frames: 40_000)
        let thrown = Self.rms(Self.echo(bass, Self.throwSettings(delay: 4_800, cut: 10_000)), 11_500..<14_500)
        let tone = Self.sine(1_000, frames: 40_000)
        let kept = Self.rms(Self.echo(tone, Self.throwSettings(delay: 4_800, cut: 10_000)), 11_500..<14_500)
        #expect(thrown < kept * 0.35, "bass \(thrown), tone \(kept)")
    }

    // MARK: Low-pass sweep

    @Test("the low-pass sweep begins without a step, also in the middle of a wave")
    func lowpassSweepBegins() {
        let sweep = MusicFilterSweep(sampleRate: Self.rate)
        sweep.start(MusicSweepSettings(startFrame: 0, durationFrames: 48_000, fromHz: 18_000, toHz: 300, highpass: false))
        let out = Self.left(sweep.render(Self.stereo([Float](repeating: 0.5, count: 64))))
        #expect(out.allSatisfy { abs($0 - 0.5) < 1e-4 })
    }

    @Test("the reverb's ceiling passes what is quiet, never passes 1 and makes silence of what is not a number")
    func reverbCeiling() {
        #expect(MusicReverbTail.soft(0.5) == 0.5)
        #expect(abs(MusicReverbTail.soft(-40)) <= 1)
        #expect(MusicReverbTail.soft(.nan) == 0)
        #expect(MusicReverbTail.soft(.infinity) == 0)
    }

    @Test("the low-pass sweep starts with the whole song and ends with its lows")
    func lowpassSweep() {
        func level(_ hz: Double, _ range: Range<Int>) -> Float {
            let filter = MusicFilterSweep(sampleRate: Self.rate)
            filter.start(MusicSweepSettings(
                startFrame: 4_800, durationFrames: 48_000, fromHz: Float(MusicBeatPlanner.lowpassFromHz),
                toHz: Float(MusicBeatPlanner.lowpassToHz), highpass: false
            ))
            return Self.rms(Self.left(filter.render(Self.stereo(Self.sine(hz, frames: 96_000)))), range)
        }
        let full = Float(0.5) / Float(2).squareRoot()
        #expect(level(5_000, 1_000..<4_800) > full * 0.9, "open at the start")
        #expect(level(5_000, 80_000..<96_000) < full * 0.02, "the highs are gone at the end")
        #expect(level(80, 80_000..<96_000) > full * 0.85, "the lows are not")
        // The middle goes before the bottom: half way the filter is at about 2.3 kHz.
        #expect(level(500, 26_000..<30_000) > full * 0.9)
        #expect(level(8_000, 26_000..<30_000) < full * 0.15)
    }

    // MARK: - On a deck

    private func deck(_ chain: MusicDSPChain, claims: Bool = true) -> MusicRenderLease {
        MusicRenderLease(chain: chain, sampleRate: 48_000, maxFrames: 16_384, claims: claims)
    }

    @discardableResult
    private func play(_ lease: MusicRenderLease, _ mono: [Float]) -> [Float] {
        var out: [Float] = []
        var at = 0
        while at < mono.count {
            let chunk = Array(mono[at..<min(mono.count, at + 480)])
            let buffers = TestBufferList(channels: [chunk, chunk], layout: .interleaved)
            lease.render(buffers.list, frames: buffers.frames)
            out += buffers.samples(channel: 0)
            at += chunk.count
        }
        return out
    }

    /// A second of song, then the cut: `begin` asks for the tail, the deck is drained over 50 ms and the other one takes the chain.
    private func cutDeck(_ begin: (MusicRenderLease) -> Void) -> MusicRenderLease {
        let chain = MusicDSPChain(sampleRate: 48_000)
        let outgoing = deck(chain), incoming = deck(chain, claims: false)
        play(outgoing, Self.noise(48_000))
        begin(outgoing)
        outgoing.drain(over: 0.05, curve: .equalPower)
        incoming.claim()
        return outgoing
    }

    @Test("a tail is heard long after the deck's fade is over, then the deck is silent", arguments: [true, false])
    func tailOutlivesTheFade(isReverb: Bool) {
        let outgoing = cutDeck { lease in
            if isReverb {
                lease.reverb.begin(MusicReverbSettings(cutAfterFrames: 0, tailFrames: 48_000))
            } else {
                lease.brake.begin(MusicBrakeSettings(cutAfterFrames: 0, lengthFrames: 24_000, gain: 1))
            }
        }
        let during = play(outgoing, Self.noise(9_600))
        #expect(Self.rms(during, 4_800..<9_600) > 0.005, "the fade is over by then, the tail is not")
        #expect(outgoing.isTailActive)
        play(outgoing, Self.noise(57_600))
        #expect(!outgoing.isTailActive)
        #expect(play(outgoing, Self.noise(4_800)).allSatisfy { $0 == 0 })
    }

    @Test("a tail cut short fades out over the release, and one that is ended is gone with the next block")
    func tailsEnd() {
        let released = cutDeck { $0.reverb.begin(MusicReverbSettings(cutAfterFrames: 0, tailFrames: 96_000)) }
        play(released, Self.noise(4_800))
        released.releaseTails(over: 0.03)
        let out = play(released, Self.noise(4_800))
        #expect(Self.rms(out, 0..<240) > 0.001, "it does not step off")
        #expect(out[1_920...].allSatisfy { $0 == 0 })
        #expect(!released.isTailActive)

        let ended = cutDeck { $0.brake.begin(MusicBrakeSettings(cutAfterFrames: 0, lengthFrames: 24_000, gain: 1)) }
        play(ended, Self.noise(4_800))
        ended.endTails()
        #expect(!ended.isTailActive)
        #expect(play(ended, Self.noise(480)).allSatisfy { $0 == 0 })
    }
}
