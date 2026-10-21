// DeciTests/Music/MusicSpectrumTests.swift
// The player column's vertical spectrum, which is also the song's progress bar: the seeded curve of the design, the
// bar widths, the played count and playhead, the click-to-seek mapping, how real loudness is captured per slice and
// kept per track, how the playhead bar pulses, and the driver that feeds them. Nothing here draws a view.

import Foundation
import Testing
@testable import Deci

@Suite("MusicSpectrum curve")
struct MusicSpectrumCurveTests {
    /// The design's formula, written out here on purpose so the code is checked against the spec and not itself.
    private func specLevels(seed: Int, count: Int) -> [Double] {
        var s = seed
        return (0..<count).map { i in
            s = (s * 9301 + 49297) % 233_280
            let rnd = Double(s) / 233_280
            let q = Double(i) * 60 / Double(count)
            var v = 0.42 + 0.22 * sin(0.37 * q) + 0.18 * sin(0.13 * q + 1.1) + 0.3 * (rnd - 0.5)
            v *= min(1, Double(i + 3) / 8, Double(count - i + 2) / 8)
            return min(max(v, 0.08), 1)
        }
    }

    @Test("the generator runs s = (s x 9301 + 49297) mod 233280")
    func lcg() {
        #expect(MusicSpectrum.lcgNext(7) == 114_404)
        #expect(MusicSpectrum.lcgNext(114_404) == 130_821)
        #expect(MusicSpectrum.lcgNext(0) == 49_297)
        // Always inside the modulus.
        var s = 7
        for _ in 0..<1000 {
            s = MusicSpectrum.lcgNext(s)
            #expect(s >= 0 && s < 233_280)
        }
    }

    @Test("seed 7 gives the design's curve, bar for bar")
    func seedSevenMatchesTheSpec() {
        let levels = MusicSpectrum.seededLevels(seed: 7)
        let expected = specLevels(seed: 7, count: 28)
        #expect(levels.count == 28)
        for (got, want) in zip(levels, expected) {
            #expect(abs(got - want) < 1e-12)
        }
    }

    @Test("every level is in 0.08...1, and the ends are tapered below the middle", arguments: [0, 7, 11, 233_279, 99_999])
    func clampAndTaper(seed: Int) {
        let levels = MusicSpectrum.seededLevels(seed: seed)
        #expect(levels.allSatisfy { $0 >= 0.08 && $0 <= 1 })
        // The first bars are scaled by (i + 3) / 8, so the first is at most 3/8 of a curve that stays under 1.15.
        #expect(levels[0] <= 0.5)
        #expect(levels[27] <= 0.75)
        let middle = levels[10...17].reduce(0, +) / 8
        #expect(middle > levels[0])
    }

    @Test("a short list tapers the same way, from its own length")
    func otherCounts() {
        let levels = MusicSpectrum.seededLevels(seed: 7, count: 5)
        let expected = specLevels(seed: 7, count: 5)
        #expect(levels.count == 5)
        for (got, want) in zip(levels, expected) { #expect(abs(got - want) < 1e-12) }
        #expect(MusicSpectrum.seededLevels(seed: 7, count: 0).isEmpty)
    }

    @Test("a song's seed is the FNV-1a of its id, the same every run, and inside the modulus")
    func trackSeed() {
        let a = MusicSpectrum.seed(forVideoId: "dQw4w9WgXcQ")
        #expect(a == MusicSpectrum.seed(forVideoId: "dQw4w9WgXcQ"))
        #expect(a == Int(MusicHash.fnv1a("dQw4w9WgXcQ") % 233_280))
        #expect(a >= 0 && a < 233_280)
        #expect(MusicSpectrum.seed(forVideoId: "other") != a)
        #expect(MusicSpectrum.seed(forVideoId: "") >= 0)
    }

    @Test("two songs get two different shapes, and the same song the same shape")
    func shapesDiffer() {
        let one = MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "alpha"))
        let again = MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "alpha"))
        let two = MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "bravo"))
        #expect(one == again)
        #expect(one != two)
    }
}

@Suite("MusicSpectrum geometry")
struct MusicSpectrumGeometryTests {
    @Test("the box is 142 by 104, with 28 bars 2 thick, 3.78 apart")
    func measures() {
        #expect(MusicSpectrum.boxWidth == 142)
        #expect(MusicSpectrum.boxHeight == 104)
        #expect(MusicSpectrum.barCount == 28)
        #expect(MusicSpectrum.barThickness == 2)
        #expect(abs(MusicSpectrum.pitch - 102.0 / 27.0) < 1e-12)
        #expect(MusicSpectrum.barY(0) == 0)
        // The last bar ends on the bottom edge of the box.
        #expect(abs(MusicSpectrum.barY(27) + MusicSpectrum.barThickness - 104) < 1e-9)
    }

    @Test("a taller box spreads the 28 bars to its bottom edge and thickens them, never under the design's")
    func stretched() {
        let height = 190.0
        let thickness = MusicSpectrum.barThickness(height: height)
        #expect(thickness == 3.5)
        #expect(abs(MusicSpectrum.barY(27, height: height) + thickness - height) < 1e-9)
        #expect(MusicSpectrum.barThickness(height: 80) == 2)
        #expect(MusicSpectrum.barThickness(height: 400) == 4)
        #expect(MusicSpectrum.barY(27, height: 80) == MusicSpectrum.barY(27))
        #expect(MusicSpectrum.progress(atY: 95, height: height) == 0.5)
        #expect(MusicSpectrum.previewLineY(atY: 500, height: height) == height - 1)
    }

    @Test("the rate strip's 3 pt more under the times makes the box 188 pt instead of 191, with the same 28 bars, as thick")
    func shorterBoxForTheRateStrip() {
        // The column's 490 pt of content less the cover, the texts, the transport and the 10 pt gaps leaves the block
        // 210 pt: the box, 6 pt, the 13 pt times row, and now the 3 pt the times sit further from the transport. The
        // strip itself is out of the layout. 191 before, 188 now.
        let before = 191.0
        let m = MusicPopupMetrics.self
        let after = before - Double(m.timesToTransport - m.playerColumnSpacing)
        #expect(after == 188)
        #expect(MusicSpectrum.barThickness(height: before) == 3.5)
        #expect(MusicSpectrum.barThickness(height: after) == 3.5)
        for height in [before, after] {
            let thickness = MusicSpectrum.barThickness(height: height)
            #expect(abs(MusicSpectrum.barY(27, height: height) + thickness - height) < 1e-9)
        }
        #expect(abs(MusicSpectrum.pitch(height: before) - 187.5 / 27) < 1e-9)
        #expect(abs(MusicSpectrum.pitch(height: after) - 169.5 / 27) < 1e-9)
        // The gap between two bars is 3.4 pt before and 2.8 pt now.
        #expect(MusicSpectrum.pitch(height: after) - 3.5 > 2.5)
        // Even the column with no song (a 67 pt text block, 35 pt more than a song's) keeps the bars well over 1.5 pt.
        #expect(MusicSpectrum.barThickness(height: after - 35) >= 1.5)
    }

    @Test("a bar is 8 + 120 x level wide, rounded to a half point")
    func widths() {
        #expect(MusicSpectrum.width(forLevel: 0.08) == 17.5)
        #expect(MusicSpectrum.width(forLevel: 1) == 128)
        #expect(MusicSpectrum.width(forLevel: 0) == 8)
        #expect(MusicSpectrum.width(forLevel: 0.5) == 68)
        // A third of the way: 8 + 40 = 48.
        #expect(MusicSpectrum.width(forLevel: 1.0 / 3.0) == 48)
        // 8 + 120 x 0.4 = 56; 8 + 120 x 0.401 = 56.12, which rounds to 56.
        #expect(MusicSpectrum.width(forLevel: 0.401) == 56)
        #expect(MusicSpectrum.width(forLevel: 0.404) == 56.5)
    }

    @Test("widths are held between 8 and 128, and a level that is not a number is the smallest bar")
    func widthLimits() {
        #expect(MusicSpectrum.width(forLevel: -4) == 8)
        #expect(MusicSpectrum.width(forLevel: 9) == 128)
        #expect(MusicSpectrum.width(forLevel: .nan) == 8)
        #expect(MusicSpectrum.width(forLevel: .infinity) == 8)
    }

    @Test("the fill's soft edge is two bars deep and slides from just above the box to just below it")
    func fillEdge() {
        let edge = MusicSpectrum.fillEdge()
        #expect(abs(edge - 2 * MusicSpectrum.pitch) < 1e-9)
        #expect(abs(MusicSpectrum.fillEdgeY(progress: 0) + edge / 2) < 1e-9)
        #expect(abs(MusicSpectrum.fillEdgeY(progress: 1) - edge / 2 - MusicSpectrum.boxHeight) < 1e-9)
        #expect(abs(MusicSpectrum.fillEdgeY(progress: 0.5) - MusicSpectrum.boxHeight / 2) < 1e-9)
        #expect(MusicSpectrum.fillEdgeY(progress: .nan) == MusicSpectrum.fillEdgeY(progress: 0))
        #expect(MusicSpectrum.fillEdgeY(progress: 9) == MusicSpectrum.fillEdgeY(progress: 1))
        let tall = 190.0
        #expect(abs(MusicSpectrum.fillEdgeY(progress: 1, height: tall) - MusicSpectrum.fillEdge(height: tall) / 2 - tall) < 1e-9)
    }

    @Test("the fill slides down smoothly: equal steps of the song move it equal steps, never a whole bar at once")
    func fillIsContinuous() {
        let ys = (0...2800).map { MusicSpectrum.fillEdgeY(progress: Double($0) / 2800, height: 190) }
        let steps = zip(ys.dropFirst(), ys).map { $0 - $1 }
        #expect(steps.allSatisfy { $0 > 0 && $0 < MusicSpectrum.pitch(height: 190) / 10 })
    }

    @Test("a glide covers a quarter of the way per poll and lands once it is close")
    func glide() {
        #expect(abs(MusicSpectrum.glided(shown: 0.2, target: 0.6) - 0.3) < 1e-12)
        #expect(abs(MusicSpectrum.glided(shown: 0.6, target: 0.2) - 0.5) < 1e-12)
        #expect(MusicSpectrum.glided(shown: 0.5, target: 0.50005) == 0.50005)
        #expect(MusicSpectrum.glided(shown: .nan, target: 0.4) == 0.4)
    }
}

@Suite("MusicSpectrum seek")
struct MusicSpectrumSeekTests {
    @Test("a click maps y to a position: the top is the start, the bottom the end")
    func mapping() {
        #expect(MusicSpectrum.progress(atY: 0) == 0)
        #expect(MusicSpectrum.progress(atY: 52) == 0.5)
        #expect(MusicSpectrum.progress(atY: 104) == 1)
    }

    @Test("a point outside the box, or not a number, is held at the nearest end")
    func clamped() {
        #expect(MusicSpectrum.progress(atY: -20) == 0)
        #expect(MusicSpectrum.progress(atY: 400) == 1)
        #expect(MusicSpectrum.progress(atY: .nan) == 0)
        #expect(MusicSpectrum.progress(atY: .infinity) == 0)
    }

    @Test("clicking the middle of any bar plays up to that bar and no further", arguments: 0..<28)
    func clickingABar(index: Int) {
        let y = MusicSpectrum.barY(index) + MusicSpectrum.barThickness / 2
        let progress = MusicSpectrum.progress(atY: y)
        // The bar sits inside the fill's soft edge: part coloured, not past it.
        #expect(abs(MusicSpectrum.fillEdgeY(progress: progress) - y) <= MusicSpectrum.fillEdge() / 2)
    }

    @Test("the position a seek asks for is the fraction of the song, never past its end")
    func seekTime() {
        #expect(MusicSpectrum.seekTime(atY: 52, duration: 200) == 100)
        #expect(MusicSpectrum.seekTime(atY: 999, duration: 200) == 200)
        #expect(MusicSpectrum.seekTime(atY: -5, duration: 200) == 0)
        #expect(MusicSpectrum.seekTime(atY: 52, duration: 0) == 0)
        #expect(MusicSpectrum.seekTime(atY: 52, duration: .nan) == 0)
    }

    @Test("the hover time is the same mapping, and the preview line follows the pointer inside the box")
    func previewLine() {
        #expect(MusicSpectrum.previewLineY(atY: 30) == 30)
        #expect(MusicSpectrum.previewLineY(atY: -4) == 0)
        #expect(MusicSpectrum.previewLineY(atY: 200) == 103)
        #expect(MusicSpectrum.previewLineY(atY: .nan) == 0)
    }
}

@Suite("MusicSpectrum real levels")
struct MusicSpectrumRealLevelTests {
    @Test("loudness maps into 0.08...1: quiet at the floor, full scale at the top")
    func mapping() throws {
        let quiet = try #require(MusicSpectrum.level(forRMS: 0.001))
        let loud = try #require(MusicSpectrum.level(forRMS: 1))
        #expect(quiet == 0.08)
        #expect(loud == 1)
    }

    @Test("louder buffers give higher levels, all the way along")
    func monotonic() throws {
        var last = 0.0
        for rms in [0.02, 0.03, 0.08, 0.15, 0.3, 0.5] as [Float] {
            let level = try #require(MusicSpectrum.level(forRMS: rms))
            #expect(level > last)
            last = level
        }
    }

    @Test("a typical music buffer lands mid-range, so the bars have room to move both ways")
    func typicalMusic() throws {
        // About -20 dBFS.
        let level = try #require(MusicSpectrum.level(forRMS: 0.1))
        #expect(level > 0.4 && level < 0.7)
    }

    @Test("no data (silence, NaN, infinity, negative) is nil, never a bar")
    func noData() {
        #expect(MusicSpectrum.level(forRMS: 0) == nil)
        #expect(MusicSpectrum.level(forRMS: .nan) == nil)
        #expect(MusicSpectrum.level(forRMS: .infinity) == nil)
        #expect(MusicSpectrum.level(forRMS: -0.5) == nil)
    }

    @Test("a level that is more than full scale is held at 1")
    func boosted() {
        #expect(MusicSpectrum.level(forRMS: 3) == 1)
    }
}

@Suite("MusicSpectrum pulse")
struct MusicSpectrumPulseTests {
    @Test("a rising target is chased at 0.3 of the gap, a falling one at 0.1")
    func attackAndRelease() {
        #expect(abs(MusicSpectrum.smoothed(current: 0.4, target: 0.8) - 0.52) < 1e-12)
        #expect(abs(MusicSpectrum.smoothed(current: 0.8, target: 0.4) - 0.76) < 1e-12)
        #expect(MusicSpectrum.smoothed(current: 0.5, target: 0.5) == 0.5)
    }

    @Test("it never overshoots the target, however often it runs")
    func settles() {
        var up = 0.1
        for _ in 0..<200 { up = MusicSpectrum.smoothed(current: up, target: 0.9) }
        #expect(abs(up - 0.9) < 1e-6)
        #expect(up <= 0.9)
        var down = 0.9
        for _ in 0..<200 { down = MusicSpectrum.smoothed(current: down, target: 0.2) }
        #expect(abs(down - 0.2) < 1e-6)
        #expect(down >= 0.2)
    }

    @Test("it falls slower than it rises, so a loud hit does not flicker")
    func calm() {
        let rise = MusicSpectrum.smoothed(current: 0.3, target: 0.7) - 0.3
        let fall = 0.7 - MusicSpectrum.smoothed(current: 0.7, target: 0.3)
        #expect(rise > fall)
    }
}

@Suite("MusicSpectrumTrack")
struct MusicSpectrumTrackTests {
    @Test("a new track shows its seeded curve and has captured nothing")
    func startsSeeded() {
        let track = MusicSpectrumTrack(videoId: "alpha")
        #expect(track.levels == MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "alpha")))
        #expect(track.capturedSlices == 0)
    }

    @Test("the level heard at a point replaces the seeded bar of the slice it falls in")
    func capturesIntoItsSlice() {
        var track = MusicSpectrumTrack(videoId: "alpha")
        let seeded = track.levels
        // Slice 5 spans progress 5/28 ... 6/28.
        track.capture(level: 0.9, progress: 5.5 / 28)
        #expect(track.levels[5] == 0.9)
        #expect(track.capturedSlices == 1)
        for i in 0..<28 where i != 5 { #expect(track.levels[i] == seeded[i]) }
    }

    @Test("several readings in one slice average into its bar")
    func averagesASlice() {
        var track = MusicSpectrumTrack(videoId: "alpha")
        track.capture(level: 0.2, progress: 0.50)
        track.capture(level: 0.4, progress: 0.51)
        track.capture(level: 0.9, progress: 0.52)
        #expect(abs(track.levels[14] - 0.5) < 1e-12)
    }

    @Test("progress at the very end lands in the last slice, and before the start in the first")
    func edges() {
        var track = MusicSpectrumTrack(videoId: "alpha")
        track.capture(level: 0.7, progress: 1)
        track.capture(level: 0.6, progress: 5)
        #expect(abs(track.levels[27] - 0.65) < 1e-12)
        track.capture(level: 0.3, progress: -1)
        #expect(track.levels[0] == 0.3)
    }

    @Test("a reading that is not a number or is zero is ignored")
    func ignoresNoise() {
        var track = MusicSpectrumTrack(videoId: "alpha")
        let seeded = track.levels
        track.capture(level: .nan, progress: 0.5)
        track.capture(level: 0, progress: 0.5)
        track.capture(level: -1, progress: 0.5)
        track.capture(level: 0.5, progress: .nan)
        #expect(track.levels == seeded)
        #expect(track.capturedSlices == 0)
    }

    @Test("a captured level is held inside 0.08...1")
    func heldInRange() {
        var track = MusicSpectrumTrack(videoId: "alpha")
        track.capture(level: 4, progress: 0.1)
        track.capture(level: 0.001, progress: 0.9)
        #expect(track.levels[2] == 1)
        #expect(track.levels[25] == 0.08)
    }
}

@Suite("MusicSpectrumMemory")
struct MusicSpectrumMemoryTests {
    @Test("a song played twice shows what it was captured as, and a new one starts seeded")
    func remembersATrack() {
        var memory = MusicSpectrumMemory(capacity: 4)
        memory.capture(videoId: "a", level: 0.9, progress: 0.5)
        #expect(memory.levels(for: "a")[14] == 0.9)
        #expect(memory.levels(for: "b") == MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "b")))
    }

    @Test("it keeps the most recent tracks and drops the oldest one past its capacity")
    func evictsTheLeastRecentlyUsed() {
        var memory = MusicSpectrumMemory(capacity: 3)
        for id in ["a", "b", "c"] { memory.capture(videoId: id, level: 0.9, progress: 0.5) }
        #expect(memory.count == 3)

        memory.capture(videoId: "d", level: 0.9, progress: 0.5)
        #expect(memory.count == 3)
        #expect(memory.contains("a") == false)
        #expect(memory.contains("b") && memory.contains("c") && memory.contains("d"))
    }

    @Test("capturing into a track counts as using it, so it outlives an idle one")
    func captureRefreshes() {
        var memory = MusicSpectrumMemory(capacity: 3)
        for id in ["a", "b", "c"] { memory.capture(videoId: id, level: 0.9, progress: 0.5) }
        memory.capture(videoId: "a", level: 0.8, progress: 0.6)
        memory.capture(videoId: "d", level: 0.9, progress: 0.5)
        #expect(memory.contains("a"))
        #expect(memory.contains("b") == false)
    }

    @Test("a dropped track goes back to its seeded curve")
    func evictedTrackIsSeededAgain() {
        var memory = MusicSpectrumMemory(capacity: 1)
        memory.capture(videoId: "a", level: 0.9, progress: 0.5)
        memory.capture(videoId: "b", level: 0.9, progress: 0.5)
        #expect(memory.levels(for: "a") == MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "a")))
    }

    @Test("reading a track does not store it")
    func readingStoresNothing() {
        let memory = MusicSpectrumMemory(capacity: 2)
        _ = memory.levels(for: "a")
        #expect(memory.count == 0)
    }

    @Test("the default holds 32 tracks")
    func defaultCapacity() {
        var memory = MusicSpectrumMemory()
        for i in 0..<40 { memory.capture(videoId: "t\(i)", level: 0.5, progress: 0.5) }
        #expect(memory.count == 32)
        #expect(memory.contains("t0") == false)
        #expect(memory.contains("t39"))
    }

    @Test("a capacity below one still holds one track")
    func tinyCapacity() {
        var memory = MusicSpectrumMemory(capacity: 0)
        memory.capture(videoId: "a", level: 0.5, progress: 0.5)
        #expect(memory.count == 1)
    }
}

@MainActor
@Suite("MusicSpectrumDriver")
struct MusicSpectrumDriverTests {
    /// A song 200 s long at `position`, hearing `level` on each poll.
    private final class Feed {
        var level: Float = 0
        var position: TimeInterval = 0
        var duration: TimeInterval = 200
        var videoId: String? = "song"
        var reduceMotion = false
        var polls = 0
    }

    private func driver(_ feed: Feed) -> MusicSpectrumDriver {
        MusicSpectrumDriver(sources: .init(
            level: { feed.polls += 1; return feed.level },
            position: { feed.position },
            duration: { feed.duration },
            videoId: { feed.videoId },
            reduceMotion: { feed.reduceMotion }
        ))
    }

    @Test("a poll captures the loudness it hears into the slice being played")
    func tickCaptures() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 100.5 // slice 14
        feed.level = 0.1
        driver.tick()
        let expected = MusicSpectrum.level(forRMS: 0.1)
        #expect(driver.memory.levels(for: "song")[14] == expected)
    }

    @Test("a poll with no sound captures nothing and the bars keep their seeded shape")
    func silenceCapturesNothing() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 50
        driver.tick()
        #expect(driver.memory.contains("song") == false)
        #expect(driver.pulse == nil)
    }

    @Test("the bar under the playhead pulses toward the live level, smoothed")
    func pulseChases() throws {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 10
        feed.level = 0.1
        driver.tick()
        let first = try #require(driver.pulse)
        #expect(first == MusicSpectrum.level(forRMS: 0.1))

        feed.level = 0.4
        driver.tick()
        let second = try #require(driver.pulse)
        let target = try #require(MusicSpectrum.level(forRMS: 0.4))
        #expect(second > first)
        #expect(second < target)
        #expect(abs(second - MusicSpectrum.smoothed(current: first, target: target)) < 1e-12)
    }

    @Test("the pulse keeps going across a slice boundary instead of starting over")
    func pulseCrossesSlices() throws {
        let feed = Feed()
        let driver = driver(feed)
        feed.level = 0.1
        feed.position = 10
        driver.tick()
        let before = try #require(driver.pulse)
        feed.position = 15 // the next slice
        driver.tick()
        #expect(driver.pulseIndex == 2)
        #expect(driver.pulse == before)
    }

    @Test("a different song starts the pulse over")
    func newSongResets() throws {
        let feed = Feed()
        let driver = driver(feed)
        feed.level = 0.4
        feed.position = 10
        driver.tick()
        feed.videoId = "other"
        feed.level = 0.05
        driver.tick()
        #expect(driver.pulse == MusicSpectrum.level(forRMS: 0.05))
    }

    @Test("progress follows the live position, and is nil when nothing plays")
    func progressFollowsPosition() {
        let feed = Feed()
        let driver = driver(feed)
        #expect(driver.progress == nil)
        feed.position = 50
        feed.level = 0.1
        driver.tick()
        #expect(driver.progress == 0.25)

        feed.videoId = nil
        driver.tick()
        #expect(driver.progress == nil)
    }

    @Test("a seek glides the fill to the new position over a few polls instead of jumping")
    func seekGlides() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 20
        driver.tick()
        #expect(driver.progress == 0.1)
        feed.position = 120
        driver.tick()
        let first = driver.progress ?? 0
        #expect(first > 0.1 && first < 0.6)
        for _ in 0..<40 { driver.tick() }
        #expect(driver.progress == 0.6)
    }

    @Test("a new song, Reduce Motion and the first poll after a rest land on the position at once")
    func snaps() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 180
        driver.tick()
        feed.videoId = "next"
        feed.position = 0
        driver.tick()
        #expect(driver.progress == 0)

        feed.reduceMotion = true
        feed.position = 100
        driver.tick()
        #expect(driver.progress == 0.5)

        feed.reduceMotion = false
        driver.rest()
        feed.position = 20
        driver.tick()
        #expect(driver.progress == 0.1)
    }

    @Test("resting clears the pulse, so a paused song shows its bars at rest")
    func restClearsThePulse() {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 10
        feed.level = 0.2
        driver.tick()
        #expect(driver.pulse != nil)
        driver.rest()
        #expect(driver.pulse == nil)
        #expect(driver.progress == nil)
    }

    @Test("no duration yet means nothing to place a slice on")
    func unknownDuration() {
        let feed = Feed()
        let driver = driver(feed)
        feed.duration = 0
        feed.level = 0.3
        driver.tick()
        #expect(driver.memory.contains("song") == false)
        #expect(driver.pulse == nil)
    }

    @Test("polling starts and stops with the flag, and stopping leaves the bars at rest")
    func activeFlag() {
        let feed = Feed()
        let driver = driver(feed)
        #expect(driver.isActive == false)
        driver.setActive(true)
        #expect(driver.isActive)
        driver.setActive(true)
        #expect(driver.isActive)
        driver.setActive(false)
        #expect(driver.isActive == false)
        #expect(driver.pulse == nil)
    }

    @Test("activating drops the level heard while the popup was closed, once")
    func activatingDropsTheLevelHeardWhileClosed() {
        let feed = Feed()
        let driver = driver(feed)
        driver.setActive(true)
        #expect(feed.polls == 1)
        driver.setActive(true)
        #expect(feed.polls == 1)
        driver.setActive(false)
        #expect(feed.polls == 1)
        driver.setActive(true)
        #expect(feed.polls == 2)
        driver.setActive(false)
    }

    @Test("the bars shown are the song's levels with the pulse on the bar under the playhead")
    func barsWithPulse() throws {
        let feed = Feed()
        let driver = driver(feed)
        feed.position = 100.5 // slice 14
        feed.level = 0.1
        driver.tick()
        let bars = driver.bars(for: "song")
        let pulse = try #require(driver.pulse)
        #expect(bars.count == 28)
        #expect(bars[14] == pulse)
        let stored = driver.memory.levels(for: "song")
        for i in 0..<28 where i != 14 { #expect(bars[i] == stored[i]) }
    }

    @Test("with no pulse the bars are the stored levels")
    func barsAtRest() {
        let feed = Feed()
        let driver = driver(feed)
        #expect(driver.bars(for: "song") == MusicSpectrum.seededLevels(seed: MusicSpectrum.seed(forVideoId: "song")))
    }
}
