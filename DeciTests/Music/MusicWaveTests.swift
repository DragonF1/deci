// DeciTests/Music/MusicWaveTests.swift
// The hover card's wave progress: where the playhead sits for a position, which time a click means, and the smooth
// played curve built from the per-slice levels. Pure geometry, nothing is drawn.

import CoreGraphics
import Foundation
import Testing
@testable import Deci

@Suite("Music wave geometry")
struct MusicWaveTests {
    private let width = 276.0

    @Test("the wave box is 22 pt high with a 12 pt knob, so the knob stays inside it")
    func metrics() {
        #expect(MusicWave.boxHeight == 22)
        #expect(MusicWave.knobDiameter == 12)
        #expect(MusicWave.inset == 6)
        #expect(MusicWave.baselineY + MusicWave.knobDiameter / 2 <= MusicWave.boxHeight)
        #expect(MusicWave.baselineY - MusicWave.maxAmplitude >= 0)
        #expect(MusicWave.maxAmplitude > 8)
    }

    // MARK: - Playhead and seek

    @Test("the playhead runs from the knob's half width to the other end, so the knob never clips")
    func playheadX() {
        #expect(MusicWave.playheadX(progress: 0, width: width) == 6)
        #expect(MusicWave.playheadX(progress: 1, width: width) == width - 6)
        #expect(MusicWave.playheadX(progress: 0.5, width: width) == width / 2)
    }

    @Test("a progress outside 0 to 1, or not a number, is held to the ends")
    func playheadClamps() {
        #expect(MusicWave.playheadX(progress: -3, width: width) == 6)
        #expect(MusicWave.playheadX(progress: 7, width: width) == width - 6)
        #expect(MusicWave.playheadX(progress: .nan, width: width) == 6)
    }

    @Test("a box too narrow to hold the knob puts the playhead at the inset")
    func playheadNarrow() {
        #expect(MusicWave.playheadX(progress: 0.5, width: 0) == 6)
        #expect(MusicWave.playheadX(progress: 0.5, width: 12) == 6)
        #expect(MusicWave.playheadX(progress: 0.5, width: .nan) == 6)
    }

    @Test("a click's x is turned back into a progress, and clamped at the ends")
    func progressAtX() {
        #expect(MusicWave.progress(atX: 6, width: width) == 0)
        #expect(MusicWave.progress(atX: width - 6, width: width) == 1)
        #expect(MusicWave.progress(atX: width / 2, width: width) == 0.5)
        #expect(MusicWave.progress(atX: -50, width: width) == 0)
        #expect(MusicWave.progress(atX: width + 50, width: width) == 1)
        #expect(MusicWave.progress(atX: .nan, width: width) == 0)
        #expect(MusicWave.progress(atX: 40, width: 0) == 0)
    }

    @Test("the playhead and the click are inverses of each other", arguments: [0.0, 0.1, 0.37, 0.5, 0.9, 1.0])
    func inverse(progress: Double) {
        let x = MusicWave.playheadX(progress: progress, width: width)
        #expect(abs(MusicWave.progress(atX: x, width: width) - progress) < 1e-9)
    }

    @Test("a click seeks to that share of the song")
    func seekTime() {
        #expect(MusicWave.seekTime(atX: width / 2, duration: 200, width: width) == 100)
        #expect(MusicWave.seekTime(atX: 6, duration: 200, width: width) == 0)
        #expect(MusicWave.seekTime(atX: width - 6, duration: 200, width: width) == 200)
        #expect(MusicWave.seekTime(atX: width * 5, duration: 200, width: width) == 200)
        #expect(MusicWave.seekTime(atX: -9, duration: 200, width: width) == 0)
    }

    @Test("a song with no known length seeks to the start", arguments: [0.0, -4.0, .nan, .infinity])
    func seekTimeUnknownDuration(duration: Double) {
        #expect(MusicWave.seekTime(atX: 120, duration: duration, width: width) == 0)
    }

    // MARK: - Playhead taper

    @Test("the played wave comes to a point at the playhead and is full height ten points behind it")
    func taper() {
        #expect(MusicWave.taper(distanceToPlayhead: 0) == 0)
        #expect(MusicWave.taper(distanceToPlayhead: -3) == 0)
        #expect(MusicWave.taper(distanceToPlayhead: .nan) == 0)
        #expect(MusicWave.taper(distanceToPlayhead: MusicWave.taperLength) == 1)
        #expect(MusicWave.taper(distanceToPlayhead: 500) == 1)
        let mid = MusicWave.taper(distanceToPlayhead: MusicWave.taperLength / 2)
        #expect(abs(mid - 0.5) < 1e-9)
    }

    @Test("the taper only ever grows with the distance from the playhead")
    func taperMonotone() {
        var last = -1.0
        for step in 0...40 {
            let value = MusicWave.taper(distanceToPlayhead: Double(step) * 0.5)
            #expect(value >= last)
            last = value
        }
    }

    // MARK: - Played profile

    private let levels = (0..<MusicSpectrum.barCount).map { 0.2 + 0.8 * abs(sin(Double($0) * 0.5)) }

    @Test("at the start nothing has been played, so there is no curve")
    func profileEmptyAtStart() {
        #expect(MusicWave.profile(levels: levels, progress: 0, width: width).isEmpty)
        #expect(MusicWave.profile(levels: levels, progress: -1, width: width).isEmpty)
        #expect(MusicWave.profile(levels: levels, progress: .nan, width: width).isEmpty)
        #expect(MusicWave.profile(levels: levels, progress: 0.5, width: 0).isEmpty)
    }

    @Test("the played curve runs from the left inset to the playhead")
    func profileSpan() {
        for progress in [0.05, 0.3, 0.5, 0.99, 1.0] {
            let samples = MusicWave.profile(levels: levels, progress: progress, width: width)
            #expect(samples.count >= 2)
            #expect(samples.first?.x == MusicWave.inset)
            let last = samples.last?.x ?? -1
            #expect(abs(last - MusicWave.playheadX(progress: progress, width: width)) < 1e-9)
        }
    }

    @Test("the curve's x never goes back, and its heights stay inside the box")
    func profileShape() {
        let samples = MusicWave.profile(levels: levels, progress: 0.8, width: width)
        for (index, sample) in samples.enumerated() {
            #expect(sample.height >= 0)
            #expect(sample.height <= MusicWave.maxAmplitude)
            if index > 0 { #expect(sample.x > samples[index - 1].x) }
        }
    }

    @Test("the curve ends in a point at the playhead")
    func profileEndsInPoint() {
        let samples = MusicWave.profile(levels: levels, progress: 0.6, width: width)
        #expect(samples.last?.height == 0)
        #expect((samples.dropLast().last?.height ?? 0) < MusicWave.maxAmplitude)
    }

    @Test("the same stretch of song has the same shape however far the playhead has moved")
    func profileStable() {
        let early = MusicWave.profile(levels: levels, progress: 0.3, width: width)
        let late = MusicWave.profile(levels: levels, progress: 0.9, width: width)
        let x = early[early.count / 2].x
        guard let match = late.first(where: { abs($0.x - x) < 1e-9 }) else {
            Issue.record("no sample at the same x")
            return
        }
        #expect(abs(match.height - early[early.count / 2].height) < 1e-9)
    }

    @Test("a quiet stretch sits low and a loud one rises, scaled by the level")
    func profileFollowsLevels() {
        let quiet = MusicWave.profile(levels: Array(repeating: 0.1, count: 28), progress: 1, width: width)
        let loud = MusicWave.profile(levels: Array(repeating: 1.0, count: 28), progress: 1, width: width)
        let quietMax = quiet.map(\.height).max() ?? 0
        let loudMax = loud.map(\.height).max() ?? 0
        #expect(loudMax > quietMax)
        #expect(abs(loudMax - MusicWave.maxAmplitude) < 1e-9)
    }

    @Test("the smooth curve passes through the levels it was given, and keeps the first one")
    func profilePassesThroughLevels() {
        let samples = MusicWave.profile(levels: [0.2, 0.9, 0.4], progress: 1, width: width)
        // Mid-track is the middle level; both ends are far enough from the playhead to be untapered, bar the last one.
        let middle = samples.first { abs($0.x - width / 2) < 1e-9 }
        #expect(abs((middle?.height ?? 0) - MusicWave.maxAmplitude * 0.9) < 1e-9)
        #expect(abs((samples.first?.height ?? 0) - MusicWave.maxAmplitude * 0.2) < 1e-9)
    }

    @Test("a spiky list never rises above the box, where the curve would overshoot")
    func profileSpikyStaysInRange() {
        let spiky: [Double] = [0.08, 1, 0.08, 1, 0.08, 1, 0.08]
        for sample in MusicWave.profile(levels: spiky, progress: 1, width: width) {
            #expect(sample.height >= 0)
            #expect(sample.height <= MusicWave.maxAmplitude)
        }
    }

    @Test("levels outside the range, or not numbers, are brought into it first")
    func profileDirtyLevels() {
        for sample in MusicWave.profile(levels: [-4, .nan, 9, .infinity], progress: 1, width: width) {
            #expect(sample.height.isFinite)
            #expect(sample.height >= 0)
            #expect(sample.height <= MusicWave.maxAmplitude)
        }
    }

    @Test("a single level draws a flat curve at that level, short of the playhead's taper")
    func profileSingleLevel() {
        let samples = MusicWave.profile(levels: [0.6], progress: 1, width: width)
        let end = MusicWave.playheadX(progress: 1, width: width)
        let untapered = samples.filter { $0.x <= end - MusicWave.taperLength }
        #expect(!untapered.isEmpty)
        #expect(untapered.allSatisfy { abs($0.height - MusicWave.maxAmplitude * 0.6) < 1e-9 })
    }

    @Test("no levels draws a low even line instead of nothing")
    func profileNoLevels() {
        let samples = MusicWave.profile(levels: [], progress: 0.5, width: width)
        #expect(samples.count >= 2)
        #expect(samples.allSatisfy { $0.height <= MusicWave.maxAmplitude * MusicSpectrum.minLevel + 1e-9 })
    }

    @Test("a very wide box still gives a bounded number of samples")
    func profileBounded() {
        let samples = MusicWave.profile(levels: levels, progress: 1, width: 5000)
        #expect(samples.count <= 2500)
    }

    // MARK: - Gradient

    @Test("the played fill is three colours of the cover's tint, ending on the tint itself at the playhead")
    func gradient() {
        let tint = MusicTint(hue: 0.9, saturation: 0.6, brightness: 0.8)
        let stops = MusicWave.gradientTints(for: tint)
        #expect(stops.count == 3)
        #expect(stops.last == tint)
        #expect(abs(stops[0].hue - 0.1) < 1e-9)
        #expect(abs(stops[1].hue - 0.0) < 1e-9)
        for stop in stops {
            #expect(stop.hue >= 0 && stop.hue < 1)
            #expect(stop.saturation >= 0 && stop.saturation <= 1)
            #expect(stop.brightness >= tint.brightness && stop.brightness <= 1)
        }
    }

    @Test("a tint already at full brightness stays inside the colour range", arguments: MusicTint.palette)
    func gradientInRange(tint: MusicTint) {
        for stop in MusicWave.gradientTints(for: tint) {
            #expect(stop.hue >= 0 && stop.hue < 1)
            #expect(stop.brightness <= 1)
        }
    }
}
