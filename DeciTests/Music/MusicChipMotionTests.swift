// DeciTests/Music/MusicChipMotionTests.swift
// How the Now playing chip moves: the width easing, the marquee's distance, duration and keyframes, the edge fade, and
// which change of the chip is a cross-fade of the content and which one only dims or lights it. Pure numbers: nothing
// is animated here.

import Foundation
import Testing
@testable import Deci

@Suite("Music chip motion")
struct MusicChipMotionTests {
    private func spec(
        title: String = "Night Drive",
        isPlaying: Bool = true,
        hue: Double = 0.5,
        hasThumbnail: Bool = true,
        cover: String? = "https://example.invalid/cover-a.jpg",
        reduceMotion: Bool = false
    ) -> MusicChipSpec {
        MusicChipSpec(
            title: title,
            isPlaying: isPlaying,
            tint: MusicTint(hue: hue, saturation: 0.6, brightness: 0.7),
            hasThumbnail: hasThumbnail,
            coverURL: cover.flatMap { URL(string: $0) },
            reduceMotion: reduceMotion
        )
    }

    // MARK: - Numbers

    @Test("the timings are the owner's: 0.35 s width, 0.25 s fade, 1.5 s hold, 25 pt/s, 24 pt gap")
    func constants() {
        #expect(MusicChipMotion.widthDuration == 0.35)
        #expect(MusicChipMotion.fadeDuration == 0.25)
        #expect(MusicChipMotion.marqueeHold == 1.5)
        #expect(MusicChipMotion.marqueeSpeed == 25)
        #expect(MusicChipMotion.marqueeGap == 24)
    }

    @Test("Reduce Motion makes the width change at once, otherwise it takes 0.35 s")
    func widthDuration() {
        #expect(MusicChipMotion.widthChangeDuration(reduceMotion: false) == 0.35)
        #expect(MusicChipMotion.widthChangeDuration(reduceMotion: true) == 0)
    }

    // MARK: - Which change

    @Test("a chip that was not showing gets all of its content")
    func firstContent() {
        #expect(MusicChipMotion.change(from: nil, to: spec()) == .content)
    }

    @Test("the same chip again changes nothing")
    func nothingChanged() {
        #expect(MusicChipMotion.change(from: spec(), to: spec()) == .none)
    }

    @Test("play and pause alone only dim or light the chip")
    func playbackOnly() {
        #expect(MusicChipMotion.change(from: spec(isPlaying: true), to: spec(isPlaying: false)) == .playback)
        #expect(MusicChipMotion.change(from: spec(isPlaying: false), to: spec(isPlaying: true)) == .playback)
    }

    @Test("a new title, colour, cover, cover picture or motion setting cross-fades the content")
    func contentChanges() {
        let base = spec()
        #expect(MusicChipMotion.change(from: base, to: spec(title: "Other Song")) == .content)
        #expect(MusicChipMotion.change(from: base, to: spec(hue: 0.9)) == .content)
        #expect(MusicChipMotion.change(from: base, to: spec(hasThumbnail: false)) == .content)
        #expect(MusicChipMotion.change(from: base, to: spec(cover: "https://example.invalid/cover-b.jpg")) == .content)
        #expect(MusicChipMotion.change(from: base, to: spec(cover: nil)) == .content)
        #expect(MusicChipMotion.change(from: base, to: spec(reduceMotion: true)) == .content)
    }

    @Test("a new song that also starts paused is a content change, which carries the paused look with it")
    func contentBeatsPlayback() {
        let next = spec(title: "Other Song", isPlaying: false)
        #expect(MusicChipMotion.change(from: spec(isPlaying: true), to: next) == .content)
    }

    // MARK: - When the marquee runs

    @Test("the marquee runs for a long title that plays with motion allowed, and in no other case")
    func runsMarquee() {
        #expect(MusicChipMotion.runsMarquee(scrolls: true, isPlaying: true, reduceMotion: false))
        #expect(!MusicChipMotion.runsMarquee(scrolls: false, isPlaying: true, reduceMotion: false))
        #expect(!MusicChipMotion.runsMarquee(scrolls: true, isPlaying: false, reduceMotion: false))
        #expect(!MusicChipMotion.runsMarquee(scrolls: true, isPlaying: true, reduceMotion: true))
        #expect(!MusicChipMotion.runsMarquee(scrolls: false, isPlaying: false, reduceMotion: true))
    }

    // MARK: - The marquee's path

    @Test("one loop moves the text by its own width plus the 24 pt gap, so the second copy lands where the first began")
    func distance() {
        #expect(MusicChipMotion.marqueeDistance(textWidth: 200) == 224)
        #expect(MusicChipMotion.marqueeDistance(textWidth: 0) == 24)
        #expect(MusicChipMotion.marqueeDistance(textWidth: .nan) == 24)
        #expect(MusicChipMotion.marqueeDistance(textWidth: -10) == 24)
    }

    @Test("the scroll takes distance over speed: 25 pt/s")
    func scrollDuration() {
        #expect(abs(MusicChipMotion.marqueeScrollDuration(textWidth: 200) - 8.96) < 1e-9)
        #expect(abs(MusicChipMotion.marqueeScrollDuration(textWidth: 200, speed: 50) - 4.48) < 1e-9)
    }

    @Test("a speed of zero or less does not make an endless or negative scroll", arguments: [0.0, -5.0, .nan])
    func badSpeed(speed: Double) {
        let duration = MusicChipMotion.marqueeScrollDuration(textWidth: 200, speed: speed)
        #expect(duration.isFinite)
        #expect(duration > 0)
    }

    @Test("a loop holds at the start, then scrolls: three keyframes over the whole cycle")
    func keyframes() {
        let frames = MusicChipMotion.marqueeKeyframes(textWidth: 200)
        #expect(abs(frames.duration - 10.46) < 1e-9)
        #expect(frames.offsets == [0, 0, -224])
        #expect(frames.keyTimes.count == 3)
        #expect(frames.keyTimes[0] == 0)
        #expect(abs(frames.keyTimes[1] - 1.5 / 10.46) < 1e-9)
        #expect(frames.keyTimes[2] == 1)
    }

    @Test("the text sits still for the hold, then moves left at 25 pt/s")
    func offsetOverTime() {
        #expect(MusicChipMotion.marqueeOffset(at: 0, textWidth: 200) == 0)
        #expect(MusicChipMotion.marqueeOffset(at: 1.5, textWidth: 200) == 0)
        #expect(abs(MusicChipMotion.marqueeOffset(at: 5.98, textWidth: 200) + 112) < 1e-9)
        let one = MusicChipMotion.marqueeOffset(at: 2.5, textWidth: 200)
        let two = MusicChipMotion.marqueeOffset(at: 3.5, textWidth: 200)
        #expect(abs((two - one) + 25) < 1e-9)
    }

    @Test("a loop ends with the second copy where the first began, and the next loop holds again")
    func seamlessLoop() {
        let cycle = MusicChipMotion.marqueeKeyframes(textWidth: 200).duration
        let nearEnd = MusicChipMotion.marqueeOffset(at: cycle - 1e-6, textWidth: 200)
        // The second copy is `distance` to the right of the first; scrolled by `distance`, it stands at the start.
        #expect(abs(nearEnd + MusicChipMotion.marqueeDistance(textWidth: 200)) < 0.01)
        #expect(MusicChipMotion.marqueeOffset(at: cycle, textWidth: 200) == 0)
        #expect(MusicChipMotion.marqueeOffset(at: cycle + 1.0, textWidth: 200) == 0)
        #expect(abs(MusicChipMotion.marqueeOffset(at: cycle + 1.5 + 4.48, textWidth: 200) + 112) < 1e-9)
    }

    @Test("a time before the start, or not a number, is the start")
    func offsetOutOfRange() {
        #expect(MusicChipMotion.marqueeOffset(at: -3, textWidth: 200) == 0)
        #expect(MusicChipMotion.marqueeOffset(at: .nan, textWidth: 200) == 0)
    }

    // MARK: - The edge fade

    @Test("the edges fade in just after the hold and out just before the loop ends, and stay clear during the hold")
    func edgeFadeKeyTimes() {
        let times = MusicChipMotion.edgeFadeKeyTimes(textWidth: 200)
        #expect(times.count == 5)
        #expect(times[0] == 0)
        #expect(times[4] == 1)
        // No fade through the hold: the first two stops are the start and the end of the hold.
        #expect(abs(times[1] - 1.5 / 10.46) < 1e-9)
        for index in 1..<times.count {
            #expect(times[index] > times[index - 1])
        }
        // The fade is in the scroll: it ramps in 0.3 s after the hold and out 0.3 s before the end.
        #expect(abs(times[2] - 1.8 / 10.46) < 1e-9)
        #expect(abs(times[3] - 10.16 / 10.46) < 1e-9)
    }

    @Test("even a tiny title keeps its fade stops in order", arguments: [0.0, 1.0, 5.0, .nan])
    func edgeFadeKeyTimesStayOrdered(textWidth: Double) {
        let times = MusicChipMotion.edgeFadeKeyTimes(textWidth: textWidth)
        #expect(times.first == 0)
        #expect(times.last == 1)
        for index in 1..<times.count {
            #expect(times[index] > times[index - 1])
        }
    }

    @Test("the gradient mask fades 10 pt at each edge of the window")
    func edgeFadeLocations() {
        let stops = MusicChipMotion.edgeFadeLocations(windowWidth: 100)
        #expect(stops.count == 4)
        #expect(stops[0] == 0)
        #expect(abs(stops[1] - 0.1) < 1e-9)
        #expect(abs(stops[2] - 0.9) < 1e-9)
        #expect(stops[3] == 1)
    }

    @Test("in a window narrower than the two fades they meet in the middle, and none gives no fade")
    func edgeFadeLocationsNarrow() {
        #expect(MusicChipMotion.edgeFadeLocations(windowWidth: 10) == [0, 0.5, 0.5, 1])
        #expect(MusicChipMotion.edgeFadeLocations(windowWidth: 0) == [0, 0, 1, 1])
        #expect(MusicChipMotion.edgeFadeLocations(windowWidth: .nan) == [0, 0, 1, 1])
    }

    // MARK: - Pause

    @Test("a pause eases back faster for a short way and slower for a long one, within 0.3 to 0.9 s")
    func returnDuration() {
        #expect(MusicChipMotion.marqueeReturnDuration(offset: 0) == 0.3)
        #expect(abs(MusicChipMotion.marqueeReturnDuration(offset: -75) - 0.5) < 1e-9)
        #expect(MusicChipMotion.marqueeReturnDuration(offset: -300) == 0.9)
        #expect(MusicChipMotion.marqueeReturnDuration(offset: -100_000) == 0.9)
        #expect(MusicChipMotion.marqueeReturnDuration(offset: .nan) == 0.3)
    }

    // MARK: - Easing

    @Test("ease in and out: slow start, slow end, the middle on the middle")
    func easedProgressShape() {
        #expect(MusicChipMotion.easedProgress(0) == 0)
        #expect(MusicChipMotion.easedProgress(1) == 1)
        #expect(abs(MusicChipMotion.easedProgress(0.5) - 0.5) < 1e-6)
        #expect(MusicChipMotion.easedProgress(0.1) < 0.1)
        #expect(MusicChipMotion.easedProgress(0.9) > 0.9)
        #expect(abs(MusicChipMotion.easedProgress(0.25) + MusicChipMotion.easedProgress(0.75) - 1) < 1e-6)
    }

    @Test("the easing never goes backwards")
    func easedProgressMonotonic() {
        var previous = 0.0
        for step in 0...200 {
            let value = MusicChipMotion.easedProgress(Double(step) / 200)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("progress outside 0...1 is held at the ends, and one that is not a number is the end")
    func easedProgressClamps() {
        #expect(MusicChipMotion.easedProgress(-1) == 0)
        #expect(MusicChipMotion.easedProgress(2) == 1)
        #expect(MusicChipMotion.easedProgress(.nan) == 1)
    }

    @Test("a growing width starts at the old width and ends on the new one")
    func easedWidthGrows() {
        #expect(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: 0, duration: 0.35) == 100)
        #expect(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: 0.35, duration: 0.35) == 160)
        #expect(abs(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: 0.175, duration: 0.35) - 130) < 1e-6)
    }

    @Test("a shrinking width falls in step, never below the new width")
    func easedWidthShrinks() {
        var previous = 200.0
        for step in 0...35 {
            let width = MusicChipMotion.easedWidth(from: 200, to: 120, elapsed: Double(step) * 0.01, duration: 0.35)
            #expect(width <= previous)
            #expect(width >= 120)
            previous = width
        }
        #expect(previous == 120)
    }

    @Test("a time past the end holds the new width, a time before the start the old one")
    func easedWidthClamps() {
        #expect(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: 5, duration: 0.35) == 160)
        #expect(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: -1, duration: 0.35) == 100)
    }

    @Test("no duration, or one that is not a number, is the new width at once", arguments: [0.0, -1.0, .nan, .infinity])
    func easedWidthNoDuration(duration: Double) {
        #expect(MusicChipMotion.easedWidth(from: 100, to: 160, elapsed: 0.1, duration: duration) == 160)
    }
}
